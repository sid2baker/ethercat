defmodule EtherCAT.Slave do
  @moduledoc """
  gen_statem managing the ESM (EtherCAT State Machine) lifecycle for one physical slave.

  Registered in EtherCAT.Registry under both `{:slave, name}` (atom name) and
  `{:slave_station, station}` (integer station address).

  ## Lifecycle

  Master starts a Slave with `{name, driver, config, station, pdos}` from the `slaves:`
  config list. The slave auto-advances to `:preop`: reads SII EEPROM, then self-registers
  its PDOs against the configured domains (getting logical offsets back immediately),
  writes SM and FMMU registers, then notifies the Master. The master drives the slave
  to `:safeop` and `:op` once all slaves have reached `:preop`.

  ## Usage

      # Subscribe to decoded input changes
      Slave.subscribe(:sensor, :channels, self())

      # Write outputs
      Slave.set_output(:valve, :outputs, 0xFFFF)

  ## States

      :init → :preop  (auto)
      :preop → :safeop → :op  (master-driven)
      any → :init, :preop, :safeop  (backward)
      :init ↔ :bootstrap
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.{Domain, Link, Slave.CoE, Slave.SII}
  alias EtherCAT.Link.Transaction
  alias EtherCAT.Slave.Registers

  # ns between Unix epoch (1970) and EtherCAT epoch (2000-01-01 00:00:00)
  @ethercat_epoch_offset_ns 946_684_800_000_000_000

  @al_codes %{init: 0x01, preop: 0x02, bootstrap: 0x03, safeop: 0x04, op: 0x08}

  @paths %{
    {:init, :preop} => [:preop],
    {:init, :bootstrap} => [:bootstrap],
    {:init, :safeop} => [:preop, :safeop],
    {:init, :op} => [:preop, :safeop, :op],
    {:bootstrap, :init} => [:init],
    {:preop, :safeop} => [:safeop],
    {:preop, :op} => [:safeop, :op],
    {:preop, :init} => [:init],
    {:safeop, :op} => [:op],
    {:safeop, :preop} => [:preop],
    {:safeop, :init} => [:init],
    {:op, :safeop} => [:safeop],
    {:op, :preop} => [:safeop, :preop],
    {:op, :init} => [:safeop, :preop, :init]
  }

  @poll_limit 200
  @poll_interval_ms 1

  defstruct [
    :link,
    :station,
    :name,
    :driver,
    :config,
    :error_code,
    :identity,
    :mailbox_config,
    # SYNC0 cycle time in ns — set from start_link opts; nil = no DC
    :dc_cycle_ns,
    # [{sm_index, phys_start, length, ctrl}] from SII category 0x0029
    :sii_sm_configs,
    # [%{index, direction, sm_index, bit_size, bit_offset}] from SII categories 0x0032/0x0033
    :sii_pdo_configs,
    # [{pdo_name, domain_id}] — PDOs to register in :preop enter
    :pdos,
    # %{pdo_name => %{domain_id, offset}}
    :pdo_registrations,
    # %{pdo_name => [pid]}
    :pdo_subscriptions
  ]

  # -- child_spec / start_link -----------------------------------------------

  @doc false
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary,
      shutdown: 5000
    }
  end

  @doc "Start a Slave gen_statem."
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    # Register by name (atom) for lib user API
    reg_name = {:via, Registry, {EtherCAT.Registry, {:slave, name}}}
    :gen_statem.start_link(reg_name, __MODULE__, opts, [])
  end

  # -- Public API ------------------------------------------------------------

  @doc """
  Subscribe `pid` to receive `{:slave_input, slave_name, pdo_name, decoded_value}`
  whenever the input value changes after a domain cycle.
  """
  @spec subscribe(atom(), atom(), pid()) :: :ok
  def subscribe(slave_name, pdo_name, pid) do
    :gen_statem.call(via(slave_name), {:subscribe, pdo_name, pid})
  end

  @doc """
  Encode `value` via the driver and write it to the domain ETS output slot.
  Direct ETS write via Domain — no gen_statem hop.
  """
  @spec set_output(atom(), atom(), term()) :: :ok | {:error, term()}
  def set_output(slave_name, pdo_name, value) do
    :gen_statem.call(via(slave_name), {:set_output, pdo_name, value})
  end

  @doc "Request an ESM state transition. Walks multi-step paths automatically."
  @spec request(atom(), atom()) :: :ok | {:error, term()}
  def request(slave_name, target) do
    :gen_statem.call(via(slave_name), {:request, target})
  end

  @doc "Return the current ESM state atom."
  @spec state(atom()) :: atom()
  def state(slave_name), do: :gen_statem.call(via(slave_name), :state)

  @doc "Return the identity map from SII EEPROM, or nil if not yet read."
  @spec identity(atom()) :: map() | nil
  def identity(slave_name), do: :gen_statem.call(via(slave_name), :identity)

  @doc "Return the last AL status code, or nil."
  @spec error(atom()) :: non_neg_integer() | nil
  def error(slave_name), do: :gen_statem.call(via(slave_name), :error)

  # -- :gen_statem callbacks -------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    link = Keyword.fetch!(opts, :link)
    station = Keyword.fetch!(opts, :station)
    name = Keyword.fetch!(opts, :name)
    driver = Keyword.get(opts, :driver)
    config = Keyword.get(opts, :config, %{})
    dc_cycle_ns = Keyword.get(opts, :dc_cycle_ns)
    pdos = Keyword.get(opts, :pdos, [])

    # Also register by station address for internal lookups
    Registry.register(EtherCAT.Registry, {:slave_station, station}, name)

    data = %__MODULE__{
      link: link,
      station: station,
      name: name,
      driver: driver,
      config: config,
      dc_cycle_ns: dc_cycle_ns,
      sii_sm_configs: [],
      sii_pdo_configs: [],
      pdos: pdos,
      pdo_registrations: %{},
      pdo_subscriptions: %{}
    }

    with {:ok, data2} <- do_transition(data, :init) do
      do_auto_advance(data2)
    else
      {:error, reason, _data} -> {:stop, reason}
    end
  end

  # -- State enter -----------------------------------------------------------

  @impl true
  def handle_event(:enter, _old, :init, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :preop, data) do
    invoke_driver(data, :on_preop)
    run_sdo_config(data)
    new_data = register_pdos_and_fmmus(data)
    send(EtherCAT.Master, {:slave_ready, data.name, :preop})
    {:keep_state, new_data}
  end

  def handle_event(:enter, _old, :safeop, data) do
    invoke_driver(data, :on_safeop)
    # ETG.1020 §6.3.2: configure DC SYNC after the slave confirms SAFEOP —
    # FMMUs are already written (done in :preop enter), cycle time is canonical.
    configure_sync0_if_needed(data)
    :keep_state_and_data
  end

  def handle_event(:enter, _old, :op, data) do
    invoke_driver(data, :on_op)
    :keep_state_and_data
  end

  def handle_event(:enter, _old, :bootstrap, _data), do: :keep_state_and_data

  # -- Auto-advance :init → :preop ------------------------------------------

  @auto_advance_retry_ms 200

  def handle_event({:timeout, :auto_advance}, nil, :init, data) do
    case do_auto_advance(data) do
      {:ok, :preop, new_data} -> {:next_state, :preop, new_data}
      {:ok, :init, new_data, actions} -> {:keep_state, new_data, actions}
    end
  end

  # -- ESM API calls ---------------------------------------------------------

  def handle_event({:call, from}, :state, state, _data) do
    {:keep_state_and_data, [{:reply, from, state}]}
  end

  def handle_event({:call, from}, :identity, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.identity}]}
  end

  def handle_event({:call, from}, :error, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.error_code}]}
  end

  def handle_event({:call, from}, {:request, target}, state, _data) when state == target do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:request, target}, state, data) do
    case Map.get(@paths, {state, target}) do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, :invalid_transition}}]}

      steps ->
        case walk_path(data, steps) do
          {:ok, new_data} ->
            {:next_state, target, new_data, [{:reply, from, :ok}]}

          {:error, reason, new_data} ->
            {:keep_state, new_data, [{:reply, from, {:error, reason}}]}
        end
    end
  end

  # -- Subscribe -------------------------------------------------------------

  def handle_event({:call, from}, {:subscribe, pdo_name, pid}, _state, data) do
    subs = Map.get(data.pdo_subscriptions, pdo_name, [])
    new_subs = Map.put(data.pdo_subscriptions, pdo_name, [pid | subs])
    {:keep_state, %{data | pdo_subscriptions: new_subs}, [{:reply, from, :ok}]}
  end

  # -- Set output ------------------------------------------------------------

  def handle_event({:call, from}, {:set_output, pdo_name, value}, _state, data) do
    case Map.get(data.pdo_registrations, pdo_name) do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, {:not_registered, pdo_name}}}]}

      %{domain_id: domain_id, sm_key: sm_key, bit_offset: bit_offset, bit_size: bit_size} ->
        key = {data.name, sm_key}
        encoded = data.driver.encode_outputs(pdo_name, data.config, value)

        result =
          case Domain.read(domain_id, key) do
            {:ok, current} ->
              Domain.write(domain_id, key, set_sm_bits(current, bit_offset, bit_size, encoded))

            {:error, _} = err ->
              err
          end

        {:keep_state_and_data, [{:reply, from, result}]}
    end
  end

  # -- Domain input change notification (sent by Domain on cycle) ------------

  # SM-grouped key: {slave_name, {:sm, idx}} — unpack per-PDO bits and dispatch.
  def handle_event(
        :info,
        {:domain_input, _domain_id, {_slave_name, {:sm, _} = sm_key}, sm_bytes},
        _state,
        data
      ) do
    data.pdo_registrations
    |> Enum.filter(fn {_pdo_name, reg} -> reg.sm_key == sm_key end)
    |> Enum.each(fn {pdo_name, %{bit_offset: bit_offset, bit_size: bit_size}} ->
      raw = extract_sm_bits(sm_bytes, bit_offset, bit_size)

      decoded =
        if data.driver != nil do
          data.driver.decode_inputs(pdo_name, data.config, raw)
        else
          raw
        end

      subs = Map.get(data.pdo_subscriptions, pdo_name, [])
      Enum.each(subs, &send(&1, {:slave_input, data.name, pdo_name, decoded}))
    end)

    :keep_state_and_data
  end

  # -- Catch-all -------------------------------------------------------------

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # -- Auto-advance helper (called from gen_statem init/1 and retry handler) -

  # Returns a gen_statem init tuple: {:ok, state, data} or {:ok, state, data, actions}.
  defp do_auto_advance(data) do
    case read_sii(data.link, data.station) do
      {:ok, identity, mailbox_config, sm_configs, pdo_configs} ->
        new_data = %{
          data
          | identity: identity,
            mailbox_config: mailbox_config,
            sii_sm_configs: sm_configs,
            sii_pdo_configs: pdo_configs
        }

        # Configure mailbox SMs (SM0 recv + SM1 send) while still in INIT so that
        # the slave's PDI finds them armed when it enters PREOP.
        setup_mailbox_sms(new_data)

        case do_transition(new_data, :preop) do
          {:ok, new_data2} ->
            {:ok, :preop, new_data2}

          {:error, reason, new_data2} ->
            Logger.warning(
              "[Slave #{data.name}] preop failed: #{inspect(reason)} — retrying in #{@auto_advance_retry_ms} ms"
            )

            {:ok, :init, new_data2, [{{:timeout, :auto_advance}, @auto_advance_retry_ms, nil}]}
        end

      {:error, reason} ->
        Logger.warning(
          "[Slave #{data.name}] SII read failed: #{inspect(reason)} — retrying in #{@auto_advance_retry_ms} ms"
        )

        {:ok, :init, data, [{{:timeout, :auto_advance}, @auto_advance_retry_ms, nil}]}
    end
  end

  # -- PDO self-registration (called from :preop enter) ----------------------

  defp register_pdos_and_fmmus(data) when data.driver == nil or data.pdos == [] do
    data
  end

  defp register_pdos_and_fmmus(data) do
    profile = data.driver.process_data_profile(data.config)

    # Resolve each requested PDO name to its SII PDO config entry.
    resolved =
      Enum.flat_map(data.pdos, fn {pdo_name, domain_id} ->
        case Map.get(profile, pdo_name) do
          nil ->
            Logger.warning(
              "[Slave #{data.name}] #{inspect(pdo_name)} not in driver profile — skipping"
            )

            []

          pdo_index ->
            case Enum.find(data.sii_pdo_configs, fn p -> p.index == pdo_index end) do
              nil ->
                Logger.warning(
                  "[Slave #{data.name}] PDO 0x#{Integer.to_string(pdo_index, 16)} not in SII — skipping #{inspect(pdo_name)}"
                )

                []

              pdo_cfg ->
                [{pdo_name, domain_id, pdo_cfg}]
            end
        end
      end)

    # Group by SM index — all PDOs on the same SM share one domain region and one FMMU.
    by_sm = Enum.group_by(resolved, fn {_, _, pdo_cfg} -> pdo_cfg.sm_index end)

    {new_regs, _fmmu_idx} =
      Enum.reduce(by_sm, {data.pdo_registrations, 0}, fn
        {sm_idx, sm_pdos}, {regs, fmmu_idx} ->
          register_sm_group(data, sm_idx, sm_pdos, regs, fmmu_idx)
      end)

    %{data | pdo_registrations: new_regs}
  end

  # Register all PDOs that share SM `sm_idx` as one domain region with one FMMU.
  # Bit-level packing/unpacking is done in software; the FMMU covers the whole SM byte-aligned.
  defp register_sm_group(data, sm_idx, sm_pdos, regs, fmmu_idx) do
    {_pdo_name, domain_id, first_cfg} = hd(sm_pdos)
    direction = first_cfg.direction

    case Enum.find(data.sii_sm_configs, fn {i, _, _, _} -> i == sm_idx end) do
      nil ->
        names = Enum.map(sm_pdos, &elem(&1, 0))

        Logger.warning(
          "[Slave #{data.name}] SM#{sm_idx} not found in SII — skipping #{inspect(names)}"
        )

        {regs, fmmu_idx}

      {^sm_idx, phys, _sii_len, ctrl} ->
        # Total SM byte size from all SII PDOs on this SM (driver may only request a subset)
        total_sm_bits =
          Enum.reduce(data.sii_pdo_configs, 0, fn
            %{sm_index: ^sm_idx, bit_size: b}, acc -> acc + b
            _, acc -> acc
          end)

        total_sm_size = div(total_sm_bits + 7, 8)
        fmmu_type = if direction == :input, do: 0x01, else: 0x02
        sm_key = {:sm, sm_idx}

        case Domain.register_pdo(domain_id, {data.name, sm_key}, total_sm_size, direction) do
          {:ok, offset} ->
            # SM register: full SM size, byte-aligned
            sm_reg = <<phys::16-little, total_sm_size::16-little, ctrl::8, 0::8, 0x01::8, 0::8>>

            Link.transaction(
              data.link,
              &Transaction.fpwr(&1, data.station, Registers.sm(sm_idx, sm_reg))
            )

            # One FMMU covers the entire SM, byte-aligned (start_bit=0, stop_bit=7)
            fmmu_reg =
              <<offset::32-little, total_sm_size::16-little, 0::8, 7::8, phys::16-little, 0::8,
                fmmu_type::8, 0x01::8, 0::24>>

            case Link.transaction(
                   data.link,
                   &Transaction.fpwr(&1, data.station, Registers.fmmu(fmmu_idx, fmmu_reg))
                 ) do
              {:ok, [%{wkc: wkc}]} when wkc > 0 ->
                # Record bit position metadata for each PDO in this SM group
                new_regs =
                  Enum.reduce(sm_pdos, regs, fn {pdo_name, _domain_id, pdo_cfg}, acc ->
                    Map.put(acc, pdo_name, %{
                      domain_id: domain_id,
                      sm_key: sm_key,
                      bit_offset: pdo_cfg.bit_offset,
                      bit_size: pdo_cfg.bit_size
                    })
                  end)

                {new_regs, fmmu_idx + 1}

              _ ->
                Logger.warning("[Slave #{data.name}] FMMU write for SM#{sm_idx} failed")
                {regs, fmmu_idx}
            end

          {:error, reason} ->
            Logger.warning(
              "[Slave #{data.name}] Domain.register_pdo SM#{sm_idx} failed: #{inspect(reason)}"
            )

            {regs, fmmu_idx}
        end
    end
  end

  # -- Transition helpers ----------------------------------------------------

  defp walk_path(data, []), do: {:ok, data}

  defp walk_path(data, [next | rest]) do
    case do_transition(data, next) do
      {:ok, new_data} -> walk_path(new_data, rest)
      error -> error
    end
  end

  defp do_transition(data, target) do
    code = Map.fetch!(@al_codes, target)

    with {:ok, [%{wkc: wkc}]} when wkc > 0 <-
           Link.transaction(
             data.link,
             &Transaction.fpwr(&1, data.station, Registers.al_control(code))
           ) do
      poll_al(data, code, @poll_limit)
    else
      {:ok, [%{wkc: 0}]} -> {:error, :no_response, data}
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp poll_al(data, _code, 0), do: {:error, :transition_timeout, data}

  defp poll_al(data, code, n) do
    case Link.transaction(
           data.link,
           &Transaction.fprd(&1, data.station, Registers.al_status())
         ) do
      {:ok, [%{data: <<_::3, _err::1, state::4, _::8>>, wkc: wkc}]}
      when wkc > 0 and state == code ->
        {:ok, data}

      {:ok, [%{data: <<_::3, 1::1, _::4, _::8>>, wkc: wkc}]} when wkc > 0 ->
        {err_code, new_data} = ack_error(data)
        {:error, {:al_error, err_code}, new_data}

      {:ok, [%{data: <<_::16>>, wkc: wkc}]} when wkc > 0 ->
        Process.sleep(@poll_interval_ms)
        poll_al(data, code, n - 1)

      {:ok, [%{wkc: 0}]} ->
        {:error, :no_response, data}

      {:error, reason} ->
        {:error, reason, data}
    end
  end

  defp ack_error(data) do
    err_code =
      case Link.transaction(
             data.link,
             &Transaction.fprd(&1, data.station, Registers.al_status_code())
           ) do
        {:ok, [%{data: <<c::16-little>>, wkc: wkc}]} when wkc > 0 -> c
        _ -> nil
      end

    state_code =
      case Link.transaction(
             data.link,
             &Transaction.fprd(&1, data.station, Registers.al_status())
           ) do
        {:ok, [%{data: <<_::3, _err::1, state::4, _::8>>, wkc: wkc}]} when wkc > 0 -> state
        _ -> 0x01
      end

    ack_value = state_code + 0x10

    Link.transaction(
      data.link,
      &Transaction.fpwr(&1, data.station, Registers.al_control(ack_value))
    )

    {err_code, %{data | error_code: err_code}}
  end

  # -- SII -------------------------------------------------------------------

  defp read_sii(link, station) do
    with {:ok, identity} <- SII.read_identity(link, station),
         {:ok, mailbox_config} <- SII.read_mailbox_config(link, station),
         {:ok, sm_configs} <- SII.read_sm_configs(link, station),
         {:ok, pdo_configs} <- SII.read_pdo_configs(link, station) do
      {:ok, identity, mailbox_config, sm_configs, pdo_configs}
    end
  end

  # -- Driver invocation -----------------------------------------------------

  defp invoke_driver(%{driver: nil}, _cb), do: :ok

  defp invoke_driver(data, cb) do
    if function_exported?(data.driver, cb, 2) do
      apply(data.driver, cb, [data.name, data.config])
    end

    :ok
  end

  # -- CoE SDO configuration (called from :preop enter) ----------------------

  defp run_sdo_config(%{driver: nil}), do: :ok

  defp run_sdo_config(data) do
    if function_exported?(data.driver, :sdo_config, 1) do
      Enum.each(data.driver.sdo_config(data.config), fn {index, subindex, value, size} ->
        case CoE.write_sdo(
               data.link,
               data.station,
               data.mailbox_config,
               index,
               subindex,
               value,
               size
             ) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[Slave #{data.name}] SDO write 0x#{Integer.to_string(index, 16)}:0x#{Integer.to_string(subindex, 16)} failed: #{inspect(reason)}"
            )
        end
      end)
    end

    :ok
  end

  # -- SYNC0 configuration ---------------------------------------------------

  # Configure SYNC0 on this slave if its driver profile has a `dc:` key and
  # dc_cycle_ns is set. Called from the :safeop enter handler — FMMUs are
  # already written (done in :preop enter) and the ESC has just confirmed
  # SAFEOP, so the PDI is synchronized from the first OP cycle.
  defp configure_sync0_if_needed(%{driver: nil}), do: :ok

  defp configure_sync0_if_needed(%{dc_cycle_ns: nil}), do: :ok

  defp configure_sync0_if_needed(data) do
    dc_spec =
      if function_exported?(data.driver, :dc_config, 1) do
        data.driver.dc_config(data.config)
      end

    if dc_spec != nil do
      pulse_ns = Map.fetch!(dc_spec, :sync0_pulse_ns)
      cycle_ns = data.dc_cycle_ns
      system_time_ns = System.os_time(:nanosecond) - @ethercat_epoch_offset_ns
      # start_time must be in the future relative to when the activation datagram
      # is processed by the slave (§9.2.3.6 step 6).  100 µs is ample headroom
      # for a single frame round-trip.
      start_time = system_time_ns + 100_000

      # All four writes go in one frame so the activation datagram sees the
      # already-written cycle/pulse/start values in the same processing pass.
      Link.transaction(data.link, fn tx ->
        tx
        |> Transaction.fpwr(data.station, Registers.dc_sync0_cycle_time(cycle_ns))
        |> Transaction.fpwr(data.station, Registers.dc_pulse_length(pulse_ns))
        |> Transaction.fpwr(data.station, Registers.dc_sync0_start_time(start_time))
        |> Transaction.fpwr(data.station, Registers.dc_activation(0x03))
      end)

      Logger.debug(
        "[Slave #{data.name}] SYNC0 configured: cycle=#{cycle_ns}ns pulse=#{pulse_ns}ns"
      )
    end

    :ok
  end

  # -- Mailbox SM setup -------------------------------------------------------

  # Configure SM0 (recv, master→slave) and SM1 (send, slave→master) for
  # mailbox communication using addresses from SII EEPROM. Called while still
  # in INIT so the slave's PDI firmware finds them armed on PREOP entry.
  # No-op for slaves without a mailbox (recv_size == 0).
  defp setup_mailbox_sms(%{mailbox_config: %{recv_size: 0}}), do: :ok

  defp setup_mailbox_sms(data) do
    %{recv_offset: ro, recv_size: rs, send_offset: so, send_size: ss} = data.mailbox_config

    sm0 = <<ro::16-little, rs::16-little, 0x26::8, 0::8, 0x01::8, 0::8>>
    sm1 = <<so::16-little, ss::16-little, 0x22::8, 0::8, 0x01::8, 0::8>>

    Link.transaction(data.link, fn tx ->
      tx
      |> Transaction.fpwr(data.station, Registers.sm(0, sm0))
      |> Transaction.fpwr(data.station, Registers.sm(1, sm1))
    end)
  end

  # -- Bit-level SM packing helpers ------------------------------------------

  # Extract `bit_size` bits starting at `bit_offset` from `sm_bytes`.
  # Returns a binary of ceil(bit_size / 8) bytes with the value in the LSB.
  # Bit numbering is little-endian: bit 0 is the LSB of byte 0.
  defp extract_sm_bits(sm_bytes, bit_offset, bit_size) do
    if rem(bit_offset, 8) == 0 and rem(bit_size, 8) == 0 do
      # Byte-aligned fast path
      binary_part(sm_bytes, div(bit_offset, 8), div(bit_size, 8))
    else
      # Sub-byte: extract bit_size consecutive bits from within one byte.
      # skip_high = number of MSBs above our field in the byte.
      byte_idx = div(bit_offset, 8)
      bit_in_byte = rem(bit_offset, 8)
      skip_high = 8 - bit_in_byte - bit_size
      <<_::binary-size(byte_idx), byte::8, _::binary>> = sm_bytes
      <<_::size(skip_high), val::size(bit_size), _::size(bit_in_byte)>> = <<byte>>
      <<val::size(div(bit_size + 7, 8) * 8)>>
    end
  end

  # Write `bit_size` bits from `encoded` into `sm_bytes` at `bit_offset`.
  # `encoded` is the driver's output binary; its LSB-aligned value is packed in.
  defp set_sm_bits(sm_bytes, _bit_offset, _bit_size, <<>>), do: sm_bytes

  defp set_sm_bits(sm_bytes, bit_offset, bit_size, encoded) do
    if rem(bit_offset, 8) == 0 and rem(bit_size, 8) == 0 do
      # Byte-aligned fast path
      byte_off = div(bit_offset, 8)
      byte_sz = div(bit_size, 8)
      total = byte_size(sm_bytes)
      padded = encoded <> :binary.copy(<<0>>, max(0, byte_sz - byte_size(encoded)))

      binary_part(sm_bytes, 0, byte_off) <>
        binary_part(padded, 0, byte_sz) <>
        binary_part(sm_bytes, byte_off + byte_sz, total - byte_off - byte_sz)
    else
      # Sub-byte: patch bit_size bits within one SM byte.
      byte_idx = div(bit_offset, 8)
      bit_in_byte = rem(bit_offset, 8)
      skip_high = 8 - bit_in_byte - bit_size
      <<prefix::binary-size(byte_idx), old_byte::8, suffix::binary>> = sm_bytes
      <<high::size(skip_high), _::size(bit_size), low::size(bit_in_byte)>> = <<old_byte>>
      # Take the bit_size LSBs of the first encoded byte as the new value
      <<_::size(8 - bit_size), new_val::size(bit_size)>> = binary_part(encoded, 0, 1)

      prefix <>
        <<high::size(skip_high), new_val::size(bit_size), low::size(bit_in_byte)>> <> suffix
    end
  end

  # -- Registry helpers -------------------------------------------------------

  defp via(slave_name), do: {:via, Registry, {EtherCAT.Registry, {:slave, slave_name}}}
end
