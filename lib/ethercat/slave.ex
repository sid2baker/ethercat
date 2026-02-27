defmodule EtherCAT.Slave do
  @moduledoc """
  gen_statem managing the ESM (EtherCAT State Machine) lifecycle for one physical slave.

  Registered in EtherCAT.Registry under both `{:slave, name}` (atom name) and
  `{:slave_station, station}` (integer station address).

  ## Lifecycle

  Master starts a Slave with `{name, driver, config, station}` from the `slaves:`
  config list. The slave auto-advances to `:preop` (reads SII EEPROM for identity
  verification). It then waits for the lib user to call `register_pdo/3` and
  `subscribe/3` before requesting `:safeop`.

  ## Usage

      # Wire a PDO to a domain (writes SM registers, queues FMMU for later)
      Slave.register_pdo(:sensor, :channels, :fast_domain)

      # Subscribe to decoded input changes
      Slave.subscribe(:sensor, :channels, self())

      # Advance to safeop (writes FMMUs using offsets from Domain.activate)
      Slave.request(:sensor, :safeop)

      # After Domain.activate(:fast_domain):
      receive do
        {:slave_input, :sensor, :channels, decoded_value} -> ...
      end

      # Write outputs
      Slave.set_output(:valve, :outputs, 0xFFFF)

  ## States

      :init → :preop  (auto)
      :preop → :safeop → :op  (explicit)
      any → :init, :preop, :safeop  (backward)
      :init ↔ :bootstrap
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.{Domain, Link, Slave.SII}
  alias EtherCAT.Link.Transaction
  alias EtherCAT.Slave.Registers

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
    # %{pdo_name => %{domain_id, fmmu_config, offset}}
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
  Wire a PDO to a domain.

  Must be called while the slave is in `:preop`. Writes SM registers immediately
  (physical addresses are known from the driver profile). FMMU registers are
  written later when `Domain.activate/1` sends the logical offset.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec register_pdo(atom(), atom(), atom()) :: :ok | {:error, term()}
  def register_pdo(slave_name, pdo_name, domain_id) do
    :gen_statem.call(via(slave_name), {:register_pdo, pdo_name, domain_id})
  end

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

    # Also register by station address for internal lookups
    Registry.register(EtherCAT.Registry, {:slave_station, station}, name)

    data = %__MODULE__{
      link: link,
      station: station,
      name: name,
      driver: driver,
      config: config,
      pdo_registrations: %{},
      pdo_subscriptions: %{}
    }

    with {:ok, data2} <- do_transition(data, :init) do
      {:ok, :init, data2}
    else
      {:error, reason, _data} -> {:stop, reason}
    end
  end

  # -- State enter -----------------------------------------------------------

  @impl true
  def handle_event(:enter, _old, :init, _data) do
    {:keep_state_and_data, [{{:timeout, :auto_advance}, 0, nil}]}
  end

  def handle_event(:enter, _old, state, data) when state in [:preop, :safeop, :op] do
    invoke_driver(data, :"on_#{state}")
    :keep_state_and_data
  end

  def handle_event(:enter, _old, :bootstrap, _data), do: :keep_state_and_data

  # -- Auto-advance :init → :preop ------------------------------------------

  def handle_event({:timeout, :auto_advance}, nil, :init, data) do
    case read_sii(data.link, data.station) do
      {:ok, identity, mailbox_config} ->
        new_data = %{data | identity: identity, mailbox_config: mailbox_config}

        case do_transition(new_data, :preop) do
          {:ok, new_data2} ->
            {:next_state, :preop, new_data2}

          {:error, reason, new_data2} ->
            Logger.warning("[Slave #{data.name}] preop failed: #{inspect(reason)}")
            {:keep_state, new_data2}
        end

      {:error, reason} ->
        Logger.warning("[Slave #{data.name}] SII read failed: #{inspect(reason)}")
        :keep_state_and_data
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

  # -- PDO registration (must be in :preop) ----------------------------------

  def handle_event({:call, from}, {:register_pdo, pdo_name, domain_id}, :preop, data) do
    if data.driver == nil do
      {:keep_state_and_data, [{:reply, from, {:error, :no_driver}}]}
    else
      profile = data.driver.process_data_profile(data.config)

      case Map.get(profile, pdo_name) do
        nil ->
          {:keep_state_and_data, [{:reply, from, {:error, {:unknown_pdo, pdo_name}}}]}

        pdo_spec ->
          key = {data.name, pdo_name}

          result =
            if pdo_spec.inputs_size > 0 do
              Domain.register_input(domain_id, key, pdo_spec.inputs_size)
            else
              Domain.register_output(domain_id, key, pdo_spec.outputs_size)
            end

          case result do
            :ok ->
              # Write SM registers immediately — physical addresses known now
              case write_sms(data.link, data.station, pdo_spec.sms) do
                :ok ->
                  reg = %{
                    domain_id: domain_id,
                    fmmu_config: pdo_spec.fmmus,
                    inputs_size: pdo_spec.inputs_size,
                    outputs_size: pdo_spec.outputs_size,
                    offset: :pending
                  }

                  new_regs = Map.put(data.pdo_registrations, pdo_name, reg)
                  {:keep_state, %{data | pdo_registrations: new_regs}, [{:reply, from, :ok}]}

                {:error, _} = err ->
                  {:keep_state_and_data, [{:reply, from, err}]}
              end

            {:error, _} = err ->
              {:keep_state_and_data, [{:reply, from, err}]}
          end
      end
    end
  end

  def handle_event({:call, from}, {:register_pdo, _, _}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :must_be_in_preop}}]}
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

      %{domain_id: domain_id, offset: offset} when offset != :pending ->
        key = {data.name, pdo_name}
        encoded = data.driver.encode_outputs(pdo_name, data.config, value)
        Domain.write(domain_id, key, encoded)
        {:keep_state_and_data, [{:reply, from, :ok}]}

      %{offset: :pending} ->
        {:keep_state_and_data, [{:reply, from, {:error, :domain_not_activated}}]}
    end
  end

  # -- Domain offset notification (sent by Domain.activate) ------------------

  def handle_event(
        :info,
        {:domain_offset, {_slave_name, pdo_name} = key, logical_offset},
        _state,
        data
      ) do
    case Map.get(data.pdo_registrations, pdo_name) do
      nil ->
        :keep_state_and_data

      reg ->
        # Write FMMU register with the now-known logical offset
        in_offset = if reg.inputs_size > 0, do: logical_offset, else: 0
        out_offset = if reg.outputs_size > 0, do: logical_offset, else: 0
        write_fmmus(data.link, data.station, reg.fmmu_config, out_offset, in_offset)

        # already pattern-matched above
        _ = key
        new_reg = %{reg | offset: logical_offset}
        new_regs = Map.put(data.pdo_registrations, pdo_name, new_reg)
        {:keep_state, %{data | pdo_registrations: new_regs}}
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
    {al_control_addr, _} = Registers.al_control()

    with {:ok, [%{wkc: wkc}]} when wkc > 0 <-
           Link.transaction(
             data.link,
             &Transaction.fpwr(&1, data.station, al_control_addr, <<code::16-little>>)
           ) do
      poll_al(data, code, @poll_limit)
    else
      {:ok, [%{wkc: 0}]} -> {:error, :no_response, data}
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp poll_al(data, _code, 0), do: {:error, :transition_timeout, data}

  defp poll_al(data, code, n) do
    {al_status_addr, al_status_size} = Registers.al_status()

    case Link.transaction(
           data.link,
           &Transaction.fprd(&1, data.station, al_status_addr, al_status_size)
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
    {al_status_code_addr, al_status_code_size} = Registers.al_status_code()
    {al_status_addr, al_status_size} = Registers.al_status()
    {al_control_addr, _} = Registers.al_control()

    err_code =
      case Link.transaction(
             data.link,
             &Transaction.fprd(&1, data.station, al_status_code_addr, al_status_code_size)
           ) do
        {:ok, [%{data: <<c::16-little>>, wkc: wkc}]} when wkc > 0 -> c
        _ -> nil
      end

    state_code =
      case Link.transaction(
             data.link,
             &Transaction.fprd(&1, data.station, al_status_addr, al_status_size)
           ) do
        {:ok, [%{data: <<_::3, _err::1, state::4, _::8>>, wkc: wkc}]} when wkc > 0 -> state
        _ -> 0x01
      end

    ack_value = state_code + 0x10

    Link.transaction(
      data.link,
      &Transaction.fpwr(&1, data.station, al_control_addr, <<ack_value::16-little>>)
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
    case Link.transaction(link, &Transaction.fpwr(&1, station, addr, data)) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 -> :ok
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err -> err
    end
  end

  # -- Registry helpers ------------------------------------------------------

  defp via(slave_name), do: {:via, Registry, {EtherCAT.Registry, {:slave, slave_name}}}
end
