defmodule EtherCAT.Slave do
  @moduledoc """
  gen_statem managing the ESM (EtherCAT State Machine) lifecycle for one physical slave.

  Registered in EtherCAT.Registry under both `{:slave, name}` (atom name) and
  `{:slave_station, station}` (integer station address).

  ## Lifecycle

  Master starts a Slave with one declarative process-data request from the `slaves:`
  config list. The slave auto-advances to `:preop`: reads SII EEPROM, configures
  mailbox SyncManagers, enters PREOP, then applies any requested mailbox and process-data
  configuration. The master drives the slave to `:safeop` and `:op` once all slaves
  have reached `:preop`.

  ## Usage

      # Subscribe to decoded input changes
      Slave.subscribe_input(:sensor, :channels, self())

      # Write outputs
      Slave.write_output(:valve, :outputs, 0xFFFF)

  ## States

      :init → :preop  (auto)
      :preop → :safeop → :op  (master-driven)
      any → :init, :preop, :safeop  (backward)
      :init ↔ :bootstrap
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.{Domain, Bus, Slave.CoE, Slave.SII}
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Slave.ProcessDataPlan
  alias EtherCAT.Slave.ProcessDataPlan.SmGroup
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
    :bus,
    :station,
    :name,
    :driver,
    :config,
    :error_code,
    :configuration_error,
    :identity,
    :mailbox_config,
    :mailbox_counter,
    # SYNC0 cycle time in ns — set from start_link opts; nil = no DC
    :dc_cycle_ns,
    # [{sm_index, phys_start, length, ctrl}] from SII category 0x0029
    :sii_sm_configs,
    # [%{index, direction, sm_index, bit_size, bit_offset}] from SII categories 0x0032/0x0033
    :sii_pdo_configs,
    # one of :none | {:all, domain_id} | [{signal_name, domain_id}]
    :process_data_request,
    # [{latch_id, edge}] from driver distributed_clocks/1; nil = latch polling disabled
    :active_latches,
    # poll period for hardware latch event registers while in :op
    :latch_poll_ms,
    # %{signal_name => %{domain_id, sm_key, bit_offset, bit_size}}
    :signal_registrations,
    # %{signal_name => [pid]}
    :input_subscriptions,
    # %{{latch_id, edge} => [pid]}
    latch_subscriptions: %{}
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
  Subscribe `pid` to receive `{:slave_input, slave_name, signal_name, decoded_value}`
  whenever the input signal changes after a domain cycle.
  """
  @spec subscribe_input(atom(), atom(), pid()) :: :ok
  def subscribe_input(slave_name, signal_name, pid) do
    :gen_statem.call(via(slave_name), {:subscribe, signal_name, pid})
  end

  @doc """
  Encode `value` via the driver and write it to the domain ETS output slot.
  Direct ETS write via Domain — no gen_statem hop.
  """
  @spec write_output(atom(), atom(), term()) :: :ok | {:error, term()}
  def write_output(slave_name, signal_name, value) do
    :gen_statem.call(via(slave_name), {:write_output, signal_name, value})
  end

  @doc "Request an ESM state transition. Walks multi-step paths automatically."
  @spec request(atom(), atom()) :: :ok | {:error, term()}
  def request(slave_name, target) do
    :gen_statem.call(via(slave_name), {:request, target})
  end

  @doc """
  Apply PREOP-local configuration to an already discovered slave.

  Only valid while the slave is in `:preop`. This updates driver/config/process-data
  intent and reruns the local PREOP configuration sequence.
  """
  @spec configure(atom(), keyword()) :: :ok | {:error, term()}
  def configure(slave_name, opts) when is_list(opts) do
    :gen_statem.call(via(slave_name), {:configure, opts})
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

  @doc """
  Read the decoded input value for a signal. Equivalent to the value delivered
  via `subscribe_input/3`.

  Returns `{:error, :not_ready}` until the first domain cycle completes.
  """
  @spec read_input(atom(), atom()) :: {:ok, term()} | {:error, term()}
  def read_input(slave_name, signal_name) do
    :gen_statem.call(via(slave_name), {:read_input, signal_name})
  end

  @doc """
  Download a CoE SDO value via the mailbox SyncManagers.

  This is a blocking mailbox transaction. It requires the slave mailbox to be
  configured, so it is only valid from PREOP onward.
  """
  @spec download_sdo(atom(), non_neg_integer(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def download_sdo(slave_name, index, subindex, data)
      when is_binary(data) and byte_size(data) > 0 do
    :gen_statem.call(via(slave_name), {:download_sdo, index, subindex, data})
  end

  @doc """
  Upload a CoE SDO value via the mailbox SyncManagers.

  This is a blocking mailbox transaction. It requires the slave mailbox to be
  configured, so it is only valid from PREOP onward.
  """
  @spec upload_sdo(atom(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def upload_sdo(slave_name, index, subindex) do
    :gen_statem.call(via(slave_name), {:upload_sdo, index, subindex})
  end

  @doc "Subscribe `pid` to LATCH hardware events (`{:slave_latch, slave, id, edge, timestamp_ns}`)."
  @spec subscribe_latch(atom(), 0 | 1, :pos | :neg, pid()) :: :ok
  def subscribe_latch(slave_name, latch_id, edge, pid) do
    :gen_statem.call(via(slave_name), {:subscribe_latch, latch_id, edge, pid})
  end

  # -- :gen_statem callbacks -------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    bus = Keyword.fetch!(opts, :bus)
    station = Keyword.fetch!(opts, :station)
    name = Keyword.fetch!(opts, :name)
    driver = Keyword.get(opts, :driver, EtherCAT.Slave.Driver.Default)
    config = Keyword.get(opts, :config, %{})
    dc_cycle_ns = Keyword.get(opts, :dc_cycle_ns)
    process_data_request = Keyword.get(opts, :process_data, :none)

    # Also register by station address for internal lookups
    Registry.register(EtherCAT.Registry, {:slave_station, station}, name)

    data = %__MODULE__{
      bus: bus,
      station: station,
      name: name,
      driver: driver,
      config: config,
      configuration_error: nil,
      dc_cycle_ns: dc_cycle_ns,
      mailbox_counter: 0,
      sii_sm_configs: [],
      sii_pdo_configs: [],
      process_data_request: process_data_request,
      active_latches: nil,
      latch_poll_ms: nil,
      signal_registrations: %{},
      input_subscriptions: %{},
      latch_subscriptions: %{}
    }

    initialize_to_preop(data)
  end

  # -- State enter -----------------------------------------------------------

  @impl true
  def handle_event(:enter, _old, :init, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :preop, data) do
    new_data = configure_preop_process_data(data)

    Logger.debug(
      "[Slave #{data.name}] preop: ready (#{map_size(new_data.signal_registrations)} signal(s) registered)"
    )

    send(EtherCAT.Master, {:slave_ready, data.name, :preop})
    {:keep_state, new_data}
  end

  def handle_event(:enter, _old, :safeop, data) do
    invoke_driver(data, :on_safeop)
    # ETG.1020 §6.3.2: configure DC SYNC after the slave confirms SAFEOP —
    # FMMUs are already written (done in :preop enter), cycle time is canonical.
    new_data = configure_dc_signals(data)
    {:keep_state, new_data}
  end

  def handle_event(:enter, _old, :op, data) do
    invoke_driver(data, :on_op)

    actions =
      if data.latch_poll_ms do
        [{:state_timeout, data.latch_poll_ms, :latch_poll}]
      else
        []
      end

    {:keep_state_and_data, actions}
  end

  def handle_event(:enter, _old, :bootstrap, _data), do: :keep_state_and_data

  # -- Spec init → preop sequence -------------------------------------------

  @auto_advance_retry_ms 200

  def handle_event({:timeout, :auto_advance}, nil, :init, data) do
    case initialize_to_preop(data) do
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

  def handle_event({:call, from}, {:request, target}, :preop, %{configuration_error: reason})
      when target in [:safeop, :op] and not is_nil(reason) do
    {:keep_state_and_data, [{:reply, from, {:error, {:preop_configuration_failed, reason}}}]}
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

  def handle_event({:call, from}, {:configure, opts}, :preop, data) do
    case maybe_reconfigure_preop(data, opts) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, reason, new_data} ->
        {:keep_state, new_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, {:configure, _opts}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_preop}}]}
  end

  # -- Subscribe -------------------------------------------------------------

  def handle_event({:call, from}, {:subscribe, signal_name, pid}, _state, data) do
    subs = Map.get(data.input_subscriptions, signal_name, [])
    new_subs = Map.put(data.input_subscriptions, signal_name, [pid | subs])
    {:keep_state, %{data | input_subscriptions: new_subs}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:subscribe_latch, latch_id, edge, pid}, _state, data)
      when latch_id in [0, 1] and edge in [:pos, :neg] do
    key = {latch_id, edge}
    subs = Map.get(data.latch_subscriptions, key, [])
    new_subs = Map.put(data.latch_subscriptions, key, [pid | subs])
    {:keep_state, %{data | latch_subscriptions: new_subs}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:subscribe_latch, _latch_id, _edge, _pid}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  # -- Set output ------------------------------------------------------------

  def handle_event({:call, from}, {:write_output, signal_name, value}, _state, data) do
    case Map.get(data.signal_registrations, signal_name) do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, {:not_registered, signal_name}}}]}

      %{domain_id: domain_id, sm_key: sm_key, bit_offset: bit_offset, bit_size: bit_size} ->
        key = {data.name, sm_key}
        encoded = data.driver.encode_signal(signal_name, data.config, value)

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

  # -- Read input ------------------------------------------------------------

  def handle_event({:call, from}, {:read_input, signal_name}, _state, data) do
    result =
      case Map.get(data.signal_registrations, signal_name) do
        nil ->
          {:error, {:not_registered, signal_name}}

        %{domain_id: domain_id, sm_key: sm_key, bit_offset: bit_offset, bit_size: bit_size} ->
          case Domain.read(domain_id, {data.name, sm_key}) do
            {:ok, sm_bytes} ->
              raw = extract_sm_bits(sm_bytes, bit_offset, bit_size)
              {:ok, data.driver.decode_signal(signal_name, data.config, raw)}

            {:error, _} = err ->
              err
          end
      end

    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def handle_event({:call, from}, {:download_sdo, index, subindex, sdo_data}, state, data)
      when state in [:preop, :safeop, :op] do
    case mailbox_download(data, index, subindex, sdo_data) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, {:download_sdo, _index, _subindex, _sdo_data}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :mailbox_not_ready}}]}
  end

  def handle_event({:call, from}, {:upload_sdo, index, subindex}, state, data)
      when state in [:preop, :safeop, :op] do
    case mailbox_upload(data, index, subindex) do
      {:ok, value, new_data} ->
        {:keep_state, new_data, [{:reply, from, {:ok, value}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, {:upload_sdo, _index, _subindex}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :mailbox_not_ready}}]}
  end

  # -- Domain input change notification (sent by Domain on cycle) ------------

  # SM-grouped key: {slave_name, {:sm, idx}} — unpack per-signal bits and dispatch.
  def handle_event(
        :info,
        {:domain_input, _domain_id, {_slave_name, {:sm, _} = sm_key}, old_sm_bytes, new_sm_bytes},
        _state,
        data
      ) do
    notifications =
      data.signal_registrations
      |> Enum.filter(fn {_signal_name, reg} -> reg.sm_key == sm_key end)
      |> Enum.reduce([], fn {signal_name, %{bit_offset: bit_offset, bit_size: bit_size}}, acc ->
        if signal_changed?(old_sm_bytes, new_sm_bytes, bit_offset, bit_size) do
          raw = extract_sm_bits(new_sm_bytes, bit_offset, bit_size)

          decoded =
            if data.driver != nil do
              data.driver.decode_signal(signal_name, data.config, raw)
            else
              raw
            end

          data.input_subscriptions
          |> Map.get(signal_name, [])
          |> Enum.reduce(acc, fn pid, pid_acc ->
            [{pid, signal_name, decoded} | pid_acc]
          end)
        else
          acc
        end
      end)

    Enum.each(Enum.reverse(notifications), fn {pid, signal_name, decoded} ->
      send(pid, {:slave_input, data.name, signal_name, decoded})
    end)

    :keep_state_and_data
  end

  def handle_event(:state_timeout, :latch_poll, :op, data) do
    if data.active_latches do
      case Bus.transaction(
             data.bus,
             Transaction.fprd(data.station, Registers.dc_latch_event_status()),
             latch_poll_timeout_us(data)
           ) do
        {:ok, [%{data: <<latch0_status::8, latch1_status::8>>, wkc: wkc}]} when wkc > 0 ->
          dispatch_latch_events(data, latch0_status, latch1_status)

        _ ->
          :ok
      end
    end

    actions =
      if data.latch_poll_ms do
        [{:state_timeout, data.latch_poll_ms, :latch_poll}]
      else
        []
      end

    {:keep_state_and_data, actions}
  end

  # -- Catch-all -------------------------------------------------------------

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # -- Auto-advance helper (called from gen_statem init/1 and retry handler) -

  # Returns a gen_statem init tuple: {:ok, state, data} or {:ok, state, data, actions}.
  # Reads SII EEPROM, arms mailbox SMs, and requests PREOP from the ESC.
  # Full PREOP setup (SDO config, FMMU registration, :slave_ready) runs
  # asynchronously in the :preop enter handler — slaves init concurrently.
  defp initialize_to_preop(data) do
    case do_transition(data, :init) do
      {:ok, init_data} ->
        read_sii_and_enter_preop(init_data)

      {:error, reason, init_data} ->
        Logger.warning(
          "[Slave #{data.name}] init transition failed: #{inspect(reason)} — retrying in #{@auto_advance_retry_ms} ms"
        )

        {:ok, :init, init_data, [{{:timeout, :auto_advance}, @auto_advance_retry_ms, nil}]}
    end
  end

  defp read_sii_and_enter_preop(data) do
    t0 = System.monotonic_time(:millisecond)

    Logger.debug(
      "[Slave #{data.name}] init: reading SII (station=0x#{Integer.to_string(data.station, 16)})"
    )

    case read_sii(data.bus, data.station) do
      {:ok, identity, mailbox_config, sm_configs, pdo_configs} ->
        sii_ms = System.monotonic_time(:millisecond) - t0

        Logger.debug(
          "[Slave #{data.name}] SII ok in #{sii_ms}ms — " <>
            "vendor=0x#{Integer.to_string(identity.vendor_id, 16)} " <>
            "product=0x#{Integer.to_string(identity.product_code, 16)} " <>
            "mbx_recv=#{mailbox_config.recv_size} pdos=#{length(pdo_configs)}"
        )

        new_data = %{
          data
          | identity: identity,
            mailbox_config: mailbox_config,
            sii_sm_configs: sm_configs,
            sii_pdo_configs: pdo_configs
        }

        # Configure mailbox SMs (SM0 recv + SM1 send) while still in INIT so that
        # the slave's PDI finds them armed when it enters PREOP.
        Logger.debug("[Slave #{data.name}] init: setting up mailbox SMs")
        configure_mailbox_sync_managers(new_data)

        Logger.debug("[Slave #{data.name}] init: transitioning to PREOP")

        case do_transition(new_data, :preop) do
          {:ok, new_data2} ->
            preop_ms = System.monotonic_time(:millisecond) - t0
            Logger.debug("[Slave #{data.name}] init: PREOP reached in #{preop_ms}ms total")
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

  # -- PREOP configuration (called from :preop enter) -----------------------

  defp configure_preop_process_data(%{driver: nil} = data) do
    clear_configuration_error(data)
  end

  defp configure_preop_process_data(data) do
    invoke_driver(data, :on_preop)
    Logger.debug("[Slave #{data.name}] preop: running mailbox configuration")
    Logger.debug("[Slave #{data.name}] preop: configuring process-data SyncManagers/FMMUs")

    with {:ok, mailbox_data} <- run_mailbox_config(data),
         {:ok, requested_signals} <-
           ProcessDataPlan.normalize_request(
             data.process_data_request,
             mailbox_data.driver,
             mailbox_data.config
           ),
         {:ok, sm_groups} <-
           ProcessDataPlan.build(
             requested_signals,
             mailbox_data.driver.process_data_model(mailbox_data.config),
             mailbox_data.sii_pdo_configs,
             mailbox_data.sii_sm_configs
           ),
         {:ok, registrations} <- apply_process_data_groups(mailbox_data, sm_groups) do
      %{clear_configuration_error(mailbox_data) | signal_registrations: registrations}
    else
      {:error, reason} ->
        log_process_data_error(data, reason)
        %{data | configuration_error: reason}
    end
  end

  defp clear_configuration_error(data) do
    %{data | configuration_error: nil}
  end

  defp maybe_reconfigure_preop(%{signal_registrations: registrations} = data, opts)
       when map_size(registrations) > 0 do
    requested_driver = Keyword.get(opts, :driver, data.driver)
    requested_config = Keyword.get(opts, :config, data.config)
    requested_process_data = Keyword.get(opts, :process_data, data.process_data_request)

    if requested_driver == data.driver and requested_config == data.config and
         requested_process_data == data.process_data_request do
      {:ok, data}
    else
      {:error, :already_configured, data}
    end
  end

  defp maybe_reconfigure_preop(data, opts) do
    updated_data = %{
      data
      | driver: Keyword.get(opts, :driver, data.driver),
        config: Keyword.get(opts, :config, data.config),
        process_data_request: Keyword.get(opts, :process_data, data.process_data_request)
    }

    configured = configure_preop_process_data(updated_data)

    case configured.configuration_error do
      nil -> {:ok, configured}
      reason -> {:error, reason, configured}
    end
  end

  defp apply_process_data_groups(data, sm_groups) do
    sm_groups
    |> Enum.reduce_while({:ok, data.signal_registrations, 0}, fn sm_group,
                                                                 {:ok, regs, fmmu_idx} ->
      case apply_process_data_group(data, sm_group, regs, fmmu_idx) do
        {:ok, new_regs, next_fmmu_idx} -> {:cont, {:ok, new_regs, next_fmmu_idx}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, registrations, _fmmu_idx} -> {:ok, registrations}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_process_data_group(data, %SmGroup{} = sm_group, regs, fmmu_idx) do
    with {:ok, offset} <-
           register_process_data_domain(data, sm_group),
         :ok <- write_process_data_sync_manager(data, sm_group),
         :ok <- write_process_data_fmmu(data, sm_group, fmmu_idx, offset),
         :ok <- activate_process_data_sync_manager(data, sm_group) do
      {:ok, register_sm_group(sm_group, regs), fmmu_idx + 1}
    end
  end

  defp register_process_data_domain(data, %SmGroup{} = sm_group) do
    case Domain.register_pdo(
           sm_group.domain_id,
           {data.name, sm_group.sm_key},
           sm_group.total_sm_size,
           sm_group.direction
         ) do
      {:ok, offset} -> {:ok, offset}
      {:error, reason} -> {:error, {:domain_register_failed, sm_group.sm_index, reason}}
    end
  end

  defp register_sm_group(%SmGroup{} = sm_group, regs) do
    Enum.reduce(sm_group.registrations, regs, fn registration, acc ->
      Map.put(acc, registration.signal_name, %{
        domain_id: registration.domain_id,
        sm_key: sm_group.sm_key,
        bit_offset: registration.bit_offset,
        bit_size: registration.bit_size
      })
    end)
  end

  defp write_process_data_sync_manager(data, %SmGroup{} = sm_group) do
    sm_reg =
      <<sm_group.phys::16-little, sm_group.total_sm_size::16-little, sm_group.ctrl::8, 0::8,
        0x00::8, 0::8>>

    case Bus.transaction(
           data.bus,
           Transaction.new()
           |> Transaction.fpwr(data.station, Registers.sm_activate(sm_group.sm_index, 0))
           |> Transaction.fpwr(data.station, Registers.sm(sm_group.sm_index, sm_reg))
         ) do
      {:ok, replies} ->
        ensure_positive_wkcs(replies, {:sync_manager_write_failed, sm_group.sm_index})

      {:error, reason} ->
        {:error, {:sync_manager_write_failed, sm_group.sm_index, reason}}
    end
  end

  defp write_process_data_fmmu(data, %SmGroup{} = sm_group, fmmu_idx, offset) do
    fmmu_reg =
      <<offset::32-little, sm_group.total_sm_size::16-little, 0::8, 7::8,
        sm_group.phys::16-little, 0::8, sm_group.fmmu_type::8, 0x01::8, 0::24>>

    case Bus.transaction(
           data.bus,
           Transaction.fpwr(data.station, Registers.fmmu(fmmu_idx, fmmu_reg))
         ) do
      {:ok, replies} ->
        ensure_positive_wkcs(replies, {:fmmu_write_failed, sm_group.sm_index})

      {:error, reason} ->
        {:error, {:fmmu_write_failed, sm_group.sm_index, reason}}
    end
  end

  defp activate_process_data_sync_manager(data, %SmGroup{} = sm_group) do
    case Bus.transaction(
           data.bus,
           Transaction.fpwr(data.station, Registers.sm_activate(sm_group.sm_index, 1))
         ) do
      {:ok, replies} ->
        ensure_positive_wkcs(replies, {:sync_manager_activate_failed, sm_group.sm_index})

      {:error, reason} ->
        {:error, {:sync_manager_activate_failed, sm_group.sm_index, reason}}
    end
  end

  defp ensure_positive_wkcs(replies, error_tag) when is_list(replies) and replies != [] do
    if all_wkc_positive?(replies) do
      :ok
    else
      {:error, error_tag}
    end
  end

  defp ensure_positive_wkcs(_replies, error_tag), do: {:error, error_tag}

  defp log_process_data_error(data, :invalid_process_data_request) do
    Logger.warning("[Slave #{data.name}] invalid process_data request")
  end

  defp log_process_data_error(data, {:signal_not_in_driver_model, signal_name}) do
    Logger.warning("[Slave #{data.name}] #{inspect(signal_name)} not in driver model")
  end

  defp log_process_data_error(data, {:invalid_signal_model, signal_name}) do
    Logger.warning(
      "[Slave #{data.name}] #{inspect(signal_name)} has an invalid signal declaration"
    )
  end

  defp log_process_data_error(data, {:pdo_not_in_sii, pdo_index}) do
    Logger.warning("[Slave #{data.name}] PDO 0x#{Integer.to_string(pdo_index, 16)} not in SII")
  end

  defp log_process_data_error(data, {:signal_range_out_of_bounds, signal_name, pdo_index}) do
    Logger.warning(
      "[Slave #{data.name}] #{inspect(signal_name)} exceeds PDO 0x#{Integer.to_string(pdo_index, 16)} bounds"
    )
  end

  defp log_process_data_error(data, {:sm_not_in_sii, sm_index}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} not found in SII")
  end

  defp log_process_data_error(data, {:sync_manager_spans_multiple_domains, sm_index}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} cannot span multiple domains")
  end

  defp log_process_data_error(data, {:mailbox_config_failed, index, subindex, reason}) do
    Logger.warning(
      "[Slave #{data.name}] mailbox step 0x#{Integer.to_string(index, 16)}:0x#{Integer.to_string(subindex, 16)} failed: #{inspect(reason)}"
    )
  end

  defp log_process_data_error(data, {:invalid_mailbox_step, step}) do
    Logger.warning("[Slave #{data.name}] invalid mailbox step: #{inspect(step)}")
  end

  defp log_process_data_error(data, {:domain_register_failed, sm_index, reason}) do
    Logger.warning(
      "[Slave #{data.name}] domain registration for SM#{sm_index} failed: #{inspect(reason)}"
    )
  end

  defp log_process_data_error(data, {:sync_manager_write_failed, sm_index, reason}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} write failed: #{inspect(reason)}")
  end

  defp log_process_data_error(data, {:sync_manager_activate_failed, sm_index, reason}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} activation failed: #{inspect(reason)}")
  end

  defp log_process_data_error(data, {:fmmu_write_failed, sm_index, reason}) do
    Logger.warning("[Slave #{data.name}] FMMU write for SM#{sm_index} failed: #{inspect(reason)}")
  end

  defp log_process_data_error(data, {:sync_manager_write_failed, sm_index}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} write failed")
  end

  defp log_process_data_error(data, {:sync_manager_activate_failed, sm_index}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} activation failed")
  end

  defp log_process_data_error(data, {:fmmu_write_failed, sm_index}) do
    Logger.warning("[Slave #{data.name}] FMMU write for SM#{sm_index} failed")
  end

  defp log_process_data_error(data, {:error, reason}) do
    Logger.warning("[Slave #{data.name}] process-data configuration failed: #{inspect(reason)}")
  end

  defp log_process_data_error(data, reason) do
    Logger.warning("[Slave #{data.name}] process-data configuration failed: #{inspect(reason)}")
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
    Logger.debug("[Slave #{data.name}] AL → #{target} (code=0x#{Integer.to_string(code, 16)})")

    with {:ok, [%{wkc: wkc}]} when wkc > 0 <-
           Bus.transaction(data.bus, Transaction.fpwr(data.station, Registers.al_control(code))) do
      poll_al(data, code, @poll_limit)
    else
      {:ok, [%{wkc: 0}]} ->
        Logger.warning("[Slave #{data.name}] AL → #{target}: no response (wkc=0)")
        {:error, :no_response, data}

      {:error, reason} ->
        Logger.warning("[Slave #{data.name}] AL → #{target} failed: #{inspect(reason)}")
        {:error, reason, data}
    end
  end

  defp poll_al(data, _code, 0), do: {:error, :transition_timeout, data}

  defp poll_al(data, code, n) do
    case Bus.transaction(data.bus, Transaction.fprd(data.station, Registers.al_status())) do
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
      case Bus.transaction(data.bus, Transaction.fprd(data.station, Registers.al_status_code())) do
        {:ok, [%{data: <<c::16-little>>, wkc: wkc}]} when wkc > 0 -> c
        _ -> nil
      end

    state_code =
      case Bus.transaction(data.bus, Transaction.fprd(data.station, Registers.al_status())) do
        {:ok, [%{data: <<_::3, _err::1, state::4, _::8>>, wkc: wkc}]} when wkc > 0 -> state
        _ -> 0x01
      end

    ack_value = state_code + 0x10

    Bus.transaction(data.bus, Transaction.fpwr(data.station, Registers.al_control(ack_value)))

    {err_code, %{data | error_code: err_code}}
  end

  # -- SII -------------------------------------------------------------------

  defp read_sii(bus, station) do
    with {:ok, identity} <- SII.read_identity(bus, station),
         {:ok, mailbox_config} <- SII.read_mailbox_config(bus, station),
         {:ok, sm_configs} <- SII.read_sm_configs(bus, station),
         {:ok, pdo_configs} <- SII.read_pdo_configs(bus, station) do
      {:ok, identity, mailbox_config, sm_configs, pdo_configs}
    end
  end

  # -- Driver invocation -----------------------------------------------------

  defp invoke_driver(data, cb), do: invoke_driver(data, cb, [])

  defp invoke_driver(%{driver: nil}, _cb, _args), do: :ok

  defp invoke_driver(data, cb, args) do
    arity = 2 + length(args)

    if function_exported?(data.driver, cb, arity) do
      apply(data.driver, cb, [data.name, data.config | args])
    end

    :ok
  end

  defp invoke_driver_call(%{driver: nil}, _cb), do: nil

  defp invoke_driver_call(data, cb) do
    if function_exported?(data.driver, cb, 1) do
      apply(data.driver, cb, [data.config])
    end
  end

  # -- PREOP mailbox configuration (called from :preop enter) ----------------

  defp run_mailbox_config(%{driver: nil} = data), do: {:ok, data}

  defp run_mailbox_config(data) do
    if function_exported?(data.driver, :mailbox_config, 1) do
      data.driver.mailbox_config(data.config)
      |> Enum.reduce_while({:ok, data}, fn step, {:ok, current_data} ->
        case run_mailbox_step(current_data, step) do
          {:ok, next_data} -> {:cont, {:ok, next_data}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    else
      {:ok, data}
    end
  end

  defp run_mailbox_step(
         data,
         {:sdo_download, index, subindex, sdo_data}
       )
       when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 and
              is_binary(sdo_data) and byte_size(sdo_data) > 0 do
    case write_mailbox_sdo(data, index, subindex, sdo_data) do
      {:ok, new_data} ->
        {:ok, new_data}

      {:error, reason} ->
        {:error, {:mailbox_config_failed, index, subindex, reason}}
    end
  end

  defp run_mailbox_step(_data, step), do: {:error, {:invalid_mailbox_step, step}}

  defp write_mailbox_sdo(data, index, subindex, sdo_data) do
    mailbox_download(data, index, subindex, sdo_data)
  end

  defp mailbox_download(%{mailbox_config: nil}, _index, _subindex, _sdo_data) do
    {:error, :mailbox_not_ready}
  end

  defp mailbox_download(data, index, subindex, sdo_data) do
    case CoE.download_sdo(
           data.bus,
           data.station,
           data.mailbox_config,
           data.mailbox_counter,
           index,
           subindex,
           sdo_data
         ) do
      {:ok, mailbox_counter} ->
        {:ok, %{data | mailbox_counter: mailbox_counter}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mailbox_upload(%{mailbox_config: nil}, _index, _subindex) do
    {:error, :mailbox_not_ready}
  end

  defp mailbox_upload(data, index, subindex) do
    case CoE.upload_sdo(
           data.bus,
           data.station,
           data.mailbox_config,
           data.mailbox_counter,
           index,
           subindex
         ) do
      {:ok, value, mailbox_counter} ->
        {:ok, value, %{data | mailbox_counter: mailbox_counter}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- DC signal configuration -----------------------------------------------

  defp configure_dc_signals(%{driver: nil} = data), do: clear_latch_config(data)

  defp configure_dc_signals(%{dc_cycle_ns: nil} = data), do: clear_latch_config(data)

  defp configure_dc_signals(data) do
    case invoke_driver_call(data, :distributed_clocks) do
      nil ->
        clear_latch_config(data)

      dc_spec ->
        pulse_ns = Map.fetch!(dc_spec, :sync0_pulse_ns)
        cycle_ns = data.dc_cycle_ns
        sync1_cycle_ns = Map.get(dc_spec, :sync1_cycle_ns, 0)
        activation = if sync1_cycle_ns > 0, do: 0x07, else: 0x03

        system_time_ns = System.os_time(:nanosecond) - @ethercat_epoch_offset_ns
        # start_time must be in the future relative to when the activation datagram
        # is processed by the slave (§9.2.3.6 step 6).  100 µs is ample headroom
        # for a single frame round-trip.
        start_time = system_time_ns + 100_000

        {active_latches, latch0_ctrl, latch1_ctrl} =
          build_latch_config(Map.get(dc_spec, :latches, []))

        Bus.transaction(
          data.bus,
          Transaction.new()
          |> Transaction.fpwr(data.station, Registers.dc_sync0_cycle_time(cycle_ns))
          |> Transaction.fpwr(data.station, Registers.dc_sync1_cycle_time(sync1_cycle_ns))
          |> Transaction.fpwr(data.station, Registers.dc_pulse_length(pulse_ns))
          |> Transaction.fpwr(data.station, Registers.dc_sync0_start_time(start_time))
          |> Transaction.fpwr(data.station, Registers.dc_latch0_control(latch0_ctrl))
          |> Transaction.fpwr(data.station, Registers.dc_latch1_control(latch1_ctrl))
          |> Transaction.fpwr(data.station, Registers.dc_activation(activation))
        )

        active_latches_or_nil =
          if active_latches == [] do
            nil
          else
            active_latches
          end

        latch_poll_ms =
          if active_latches_or_nil do
            1
          else
            nil
          end

        Logger.debug(
          "[Slave #{data.name}] DC configured: cycle=#{cycle_ns}ns sync1=#{sync1_cycle_ns}ns pulse=#{pulse_ns}ns latches=#{inspect(active_latches_or_nil)}"
        )

        %{data | active_latches: active_latches_or_nil, latch_poll_ms: latch_poll_ms}
    end
  end

  defp clear_latch_config(data) do
    %{data | active_latches: nil, latch_poll_ms: nil}
  end

  defp build_latch_config(latches) do
    active_latches =
      latches
      |> Enum.reduce([], fn
        %{latch_id: latch_id, edge: edge}, acc when latch_id in [0, 1] and edge in [:pos, :neg] ->
          [{latch_id, edge} | acc]

        _, acc ->
          acc
      end)
      |> Enum.uniq()
      |> Enum.sort()

    latch0_ctrl = latch_control_byte(active_latches, 0)
    latch1_ctrl = latch_control_byte(active_latches, 1)
    {active_latches, latch0_ctrl, latch1_ctrl}
  end

  defp latch_control_byte(active_latches, latch_id) do
    if(Enum.member?(active_latches, {latch_id, :pos}), do: 0x01, else: 0x00) +
      if Enum.member?(active_latches, {latch_id, :neg}), do: 0x02, else: 0x00
  end

  defp dispatch_latch_events(data, latch0_status, latch1_status) do
    Enum.each(data.active_latches, fn {latch_id, edge} = key ->
      status = if latch_id == 0, do: latch0_status, else: latch1_status

      if latch_event_captured?(status, edge) do
        case read_latch_timestamp(data, latch_id, edge) do
          {:ok, timestamp_ns} ->
            msg = {:slave_latch, data.name, latch_id, edge, timestamp_ns}

            data.latch_subscriptions
            |> Map.get(key, [])
            |> Enum.each(&send(&1, msg))

            invoke_driver(data, :on_latch, [latch_id, edge, timestamp_ns])

          :error ->
            :ok
        end
      end
    end)
  end

  defp latch_event_captured?(status, :pos) do
    <<_::6, _neg::1, pos::1>> = <<status>>
    pos == 1
  end

  defp latch_event_captured?(status, :neg) do
    <<_::6, neg::1, _pos::1>> = <<status>>
    neg == 1
  end

  defp read_latch_timestamp(data, latch_id, edge) do
    reg = latch_time_register(latch_id, edge)

    case Bus.transaction(
           data.bus,
           Transaction.fprd(data.station, reg),
           latch_poll_timeout_us(data)
         ) do
      {:ok, [%{data: <<timestamp_ns::64-little>>, wkc: wkc}]} when wkc > 0 ->
        {:ok, timestamp_ns}

      _ ->
        :error
    end
  end

  defp latch_time_register(0, :pos), do: Registers.dc_latch0_pos_time()
  defp latch_time_register(0, :neg), do: Registers.dc_latch0_neg_time()
  defp latch_time_register(1, :pos), do: Registers.dc_latch1_pos_time()
  defp latch_time_register(1, :neg), do: Registers.dc_latch1_neg_time()

  defp latch_poll_timeout_us(%{latch_poll_ms: poll_ms, dc_cycle_ns: dc_cycle_ns})
       when is_integer(poll_ms) and poll_ms > 0 do
    poll_budget_us = div(poll_ms * 1_000 * 9, 10)

    cycle_budget_us =
      case dc_cycle_ns do
        cycle_ns when is_integer(cycle_ns) and cycle_ns > 0 ->
          div(cycle_ns * 9, 10)

        _ ->
          poll_budget_us
      end

    max(min(poll_budget_us, cycle_budget_us), 200)
  end

  defp latch_poll_timeout_us(_data), do: 900

  # -- Mailbox SM setup -------------------------------------------------------

  # Configure SM0 (recv, master→slave) and SM1 (send, slave→master) for
  # mailbox communication using addresses from SII EEPROM. Called while still
  # in INIT so the slave's PDI firmware finds them armed on PREOP entry.
  # No-op for slaves without a mailbox (recv_size == 0).
  defp configure_mailbox_sync_managers(%{mailbox_config: %{recv_size: 0}}), do: :ok

  defp configure_mailbox_sync_managers(data) do
    %{recv_offset: ro, recv_size: rs, send_offset: so, send_size: ss} = data.mailbox_config

    sm0 = <<ro::16-little, rs::16-little, 0x26::8, 0::8, 0x00::8, 0::8>>
    sm1 = <<so::16-little, ss::16-little, 0x22::8, 0::8, 0x00::8, 0::8>>

    Bus.transaction(
      data.bus,
      Transaction.new()
      |> Transaction.fpwr(data.station, Registers.sm_activate(0, 0))
      |> Transaction.fpwr(data.station, Registers.sm_activate(1, 0))
      |> Transaction.fpwr(data.station, Registers.sm(0, sm0))
      |> Transaction.fpwr(data.station, Registers.sm(1, sm1))
      |> Transaction.fpwr(data.station, Registers.sm_activate(0, 1))
      |> Transaction.fpwr(data.station, Registers.sm_activate(1, 1))
    )
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
      total_bits = byte_size(sm_bytes) * 8
      <<sm_value::unsigned-little-size(total_bits)>> = sm_bytes
      high_bits = total_bits - bit_offset - bit_size

      <<_::size(high_bits), raw::size(bit_size), _::size(bit_offset)>> =
        <<sm_value::size(total_bits)>>

      encoded_bits = ceil_div(bit_size, 8) * 8

      <<encoded_value::size(encoded_bits)>> =
        <<0::size(encoded_bits - bit_size), raw::size(bit_size)>>

      <<encoded_value::unsigned-little-size(encoded_bits)>>
    end
  end

  defp signal_changed?(:unset, _new_sm_bytes, _bit_offset, _bit_size), do: true

  defp signal_changed?(old_sm_bytes, new_sm_bytes, bit_offset, bit_size) do
    extract_sm_bits(old_sm_bytes, bit_offset, bit_size) !=
      extract_sm_bits(new_sm_bytes, bit_offset, bit_size)
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
      total_bits = byte_size(sm_bytes) * 8
      <<sm_value::unsigned-little-size(total_bits)>> = sm_bytes

      encoded_bits = byte_size(encoded) * 8
      <<encoded_value::unsigned-little-size(encoded_bits)>> = encoded

      field_value =
        if encoded_bits >= bit_size do
          <<_::size(encoded_bits - bit_size), field::size(bit_size)>> =
            <<encoded_value::size(encoded_bits)>>

          field
        else
          <<field::size(bit_size)>> =
            <<0::size(bit_size - encoded_bits), encoded_value::size(encoded_bits)>>

          field
        end

      high_bits = total_bits - bit_offset - bit_size

      <<high::size(high_bits), _::size(bit_size), low::size(bit_offset)>> =
        <<sm_value::size(total_bits)>>

      <<patched_value::size(total_bits)>> =
        <<high::size(high_bits), field_value::size(bit_size), low::size(bit_offset)>>

      <<patched_value::unsigned-little-size(total_bits)>>
    end
  end

  defp ceil_div(value, divisor) when is_integer(value) and is_integer(divisor) and divisor > 0 do
    div(value + divisor - 1, divisor)
  end

  defp all_wkc_positive?(replies) when is_list(replies) do
    Enum.all?(replies, fn
      %{wkc: wkc} when is_integer(wkc) and wkc > 0 -> true
      _ -> false
    end)
  end

  # -- Registry helpers -------------------------------------------------------

  defp via(slave_name), do: {:via, Registry, {EtherCAT.Registry, {:slave, slave_name}}}
end
