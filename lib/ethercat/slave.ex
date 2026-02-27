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

  alias EtherCAT.{Domain, Link, Slave.SII}
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

      %{domain_id: domain_id} ->
        key = {data.name, pdo_name}
        encoded = data.driver.encode_outputs(pdo_name, data.config, value)
        result = Domain.write(domain_id, key, encoded)
        {:keep_state_and_data, [{:reply, from, result}]}
    end
  end

  # -- Domain input change notification (sent by Domain on cycle) ------------

  def handle_event(:info, {:domain_input, _domain_id, {_slave_name, pdo_name}, raw}, _state, data) do
    decoded =
      if data.driver != nil do
        data.driver.decode_inputs(pdo_name, data.config, raw)
      else
        raw
      end

    subs = Map.get(data.pdo_subscriptions, pdo_name, [])
    msg = {:slave_input, data.name, pdo_name, decoded}
    Enum.each(subs, &send(&1, msg))
    :keep_state_and_data
  end

  # -- Catch-all -------------------------------------------------------------

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # -- Auto-advance helper (called from gen_statem init/1 and retry handler) -

  # Returns a gen_statem init tuple: {:ok, state, data} or {:ok, state, data, actions}.
  defp do_auto_advance(data) do
    case read_sii(data.link, data.station) do
      {:ok, identity, mailbox_config} ->
        new_data = %{data | identity: identity, mailbox_config: mailbox_config}

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

    new_regs =
      Enum.reduce(data.pdos, data.pdo_registrations, fn {pdo_name, domain_id}, regs ->
        case Map.get(profile, pdo_name) do
          nil ->
            Logger.warning(
              "[Slave #{data.name}] unknown PDO #{inspect(pdo_name)} in profile — skipping"
            )

            regs

          pdo_spec ->
            key = {data.name, pdo_name}

            {size, direction} =
              if pdo_spec.inputs_size > 0 do
                {pdo_spec.inputs_size, :input}
              else
                {pdo_spec.outputs_size, :output}
              end

            case Domain.register_pdo(domain_id, key, size, direction) do
              {:ok, offset} ->
                # Write SMs first — physical addresses are known from the profile
                case write_sms(data.link, data.station, pdo_spec.sms) do
                  :ok ->
                    in_offset = if direction == :input, do: offset, else: 0
                    out_offset = if direction == :output, do: offset, else: 0
                    write_fmmus(data.link, data.station, pdo_spec.fmmus, out_offset, in_offset)

                    Map.put(regs, pdo_name, %{domain_id: domain_id, offset: offset})

                  {:error, reason} ->
                    Logger.warning(
                      "[Slave #{data.name}] SM write for #{inspect(pdo_name)} failed: #{inspect(reason)}"
                    )

                    regs
                end

              {:error, reason} ->
                Logger.warning(
                  "[Slave #{data.name}] Domain.register_pdo #{inspect(pdo_name)} failed: #{inspect(reason)}"
                )

                regs
            end
        end
      end)

    %{data | pdo_registrations: new_regs}
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
    with {:ok, <<vid::32-little, pc::32-little, rev::32-little, sn::32-little>>} <-
           SII.read(link, station, 0x08, 8),
         {:ok, <<ro::16-little, rs::16-little, so::16-little, ss::16-little>>} <-
           SII.read(link, station, 0x18, 4) do
      {:ok, %{vendor_id: vid, product_code: pc, revision: rev, serial_number: sn},
       %{recv_offset: ro, recv_size: rs, send_offset: so, send_size: ss}}
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

  # -- SM / FMMU register writes ---------------------------------------------

  defp write_sms(link, station, sms) do
    Enum.reduce_while(sms, :ok, fn {idx, start, len, ctrl}, :ok ->
      reg = <<start::16-little, len::16-little, ctrl::8, 0::8, 0x01::8, 0::8>>

      case write_reg(link, station, {Registers.sm(idx), 8}, reg) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp write_fmmus(link, station, fmmus, out_offset, in_offset) do
    Enum.reduce_while(fmmus, :ok, fn {idx, phys, size, dir}, :ok ->
      type = if dir == :read, do: 0x01, else: 0x02
      log = if dir == :read, do: in_offset, else: out_offset

      reg =
        <<log::32-little, size::16-little, 0::8, 7::8, phys::16-little, 0::8, type::8, 0x01::8,
          0::24>>

      case write_reg(link, station, {Registers.fmmu(idx), 16}, reg) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp write_reg(link, station, {addr, _size}, data) do
    case Link.transaction(link, &Transaction.fpwr(&1, station, {addr, data})) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 -> :ok
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err -> err
    end
  end

  # -- SYNC0 configuration ---------------------------------------------------

  # Configure SYNC0 on this slave if its driver profile has a `dc:` key and
  # dc_cycle_ns is set. Called from the :safeop enter handler — FMMUs are
  # already written (done in :preop enter) and the ESC has just confirmed
  # SAFEOP, so the PDI is synchronized from the first OP cycle.
  defp configure_sync0_if_needed(%{driver: nil}), do: :ok

  defp configure_sync0_if_needed(%{dc_cycle_ns: nil}), do: :ok

  defp configure_sync0_if_needed(data) do
    profile = data.driver.process_data_profile(data.config)

    dc_spec =
      profile
      |> Map.values()
      |> Enum.find_value(fn pdo_spec -> Map.get(pdo_spec, :dc) end)

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

  # -- Registry helpers ------------------------------------------------------

  defp via(slave_name), do: {:via, Registry, {EtherCAT.Registry, {:slave, slave_name}}}
end
