defmodule EtherCAT.Slave do
  @moduledoc """
  EtherCAT State Machine (ESM) lifecycle for one physical slave device.

  One Slave process per named slave, registered under `{:slave, name}`.
  Manages INIT → PREOP → SAFEOP → OP transitions, mailbox configuration,
  process-data SM/FMMU setup, and DC signal programming.

  Typically driven by the master — use `EtherCAT.read_input/2`,
  `EtherCAT.write_output/3`, and `EtherCAT.subscribe/2` from the top-level API.
  Direct slave access via `request/2`, `info/1`, and `download_sdo/4` is also supported.
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.Slave.Bootstrap
  alias EtherCAT.Slave.DCSignals
  alias EtherCAT.Slave.Health
  alias EtherCAT.Slave.Mailbox
  alias EtherCAT.Slave.ProcessData
  alias EtherCAT.Slave.ProcessDataPlan.DomainAttachment
  alias EtherCAT.Slave.ProcessDataPlan.SmGroup
  alias EtherCAT.Slave.Signals
  alias EtherCAT.Slave.Transition

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
    :esc_info,
    :mailbox_config,
    :mailbox_counter,
    # SYNC0 cycle time in ns — set from start_link opts; nil = no DC
    :dc_cycle_ns,
    # %EtherCAT.Slave.Sync.Config{} from slave config; nil = no slave-local sync intent
    :sync_config,
    # [{sm_index, phys_start, length, ctrl}] from SII category 0x0029
    :sii_sm_configs,
    # [%{index, direction, sm_index, bit_size, bit_offset}] from SII categories 0x0032/0x0033
    :sii_pdo_configs,
    # one of :none | {:all, domain_id} | [{signal_name, domain_id}]
    :process_data_request,
    # %{0|1, edge} => name for named latch delivery; empty map = latch polling disabled
    :latch_names,
    # [{latch_id, edge}] from sync_config.latches; nil = latch polling disabled
    :active_latches,
    # poll period for hardware latch event registers while in :op
    :latch_poll_ms,
    # poll period for AL Status background health check while in :op; nil = disabled
    :health_poll_ms,
    # %{signal_name => %{domain_id, sm_key, bit_offset, bit_size, direction, logical_address, sm_size}}
    :signal_registrations,
    # %{{domain_id, {:sm, idx}} => [{signal_name, %{bit_offset, bit_size}}]}
    :signal_registrations_by_sm,
    # %{{:sm, idx} => [domain_id]} for output attachments that must be kept coherent
    :output_domain_ids_by_sm,
    # %{{:sm, idx} => full_sm_bytes} canonical output image shared across attached domains
    :output_sm_images,
    # %{signal_name_or_latch_name => MapSet.t(pid)}
    :subscriptions,
    # %{pid => reference()}
    subscriber_refs: %{},
    # true once a disconnected slave responds again and is waiting for master-owned reconnect authorization
    reconnect_ready?: false
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
  Subscribe `pid` to receive named signal or latch notifications.

  Messages arrive as:

    - `{:ethercat, :signal, slave_name, signal_name, decoded_value}`
    - `{:ethercat, :latch, slave_name, latch_name, timestamp_ns}`
  """
  @spec subscribe(atom(), atom(), pid()) :: :ok | {:error, :not_found}
  def subscribe(slave_name, signal_name, pid) do
    safe_call(slave_name, {:subscribe, signal_name, pid})
  end

  @doc """
  Encode `value`, stage it into the domain ETS output slot, and verify the
  staged bytes were written.

  This confirms the next process-image value held by the master. It does not
  prove the slave has already applied the value on hardware.
  """
  @spec write_output(atom(), atom(), term()) :: :ok | {:error, term()}
  def write_output(slave_name, signal_name, value) do
    safe_call(slave_name, {:write_output, signal_name, value})
  end

  @doc "Request an ESM state transition. Walks multi-step paths automatically."
  @spec request(atom(), atom()) :: :ok | {:error, term()}
  def request(slave_name, target) do
    safe_call(slave_name, {:request, target})
  end

  @doc false
  @spec authorize_reconnect(atom()) :: :ok | {:error, term()}
  def authorize_reconnect(slave_name), do: safe_call(slave_name, :authorize_reconnect)

  @doc """
  Apply PREOP-local configuration to an already discovered slave.

  Only valid while the slave is in `:preop`. This updates driver/config/process-data
  intent and reruns the local PREOP configuration sequence.
  """
  @spec configure(atom(), keyword()) :: :ok | {:error, term()}
  def configure(slave_name, opts) when is_list(opts) do
    safe_call(slave_name, {:configure, opts})
  end

  @doc false
  @spec cached_domain_offset(map(), SmGroup.t(), DomainAttachment.t()) ::
          {:ok, non_neg_integer()} | :error
  def cached_domain_offset(registrations, %SmGroup{} = sm_group, %DomainAttachment{} = attachment)
      when is_map(registrations) do
    attachment.registrations
    |> Enum.reduce_while({:ok, nil}, fn registration, {:ok, current_offset} ->
      case Map.get(registrations, registration.signal_name) do
        %{
          domain_id: domain_id,
          sm_key: sm_key,
          direction: direction,
          bit_offset: bit_offset,
          bit_size: bit_size,
          logical_address: logical_address,
          sm_size: sm_size
        }
        when domain_id == attachment.domain_id and sm_key == sm_group.sm_key and
               direction == sm_group.direction and bit_offset == registration.bit_offset and
               bit_size == registration.bit_size and is_integer(logical_address) and
               logical_address >= 0 and sm_size == sm_group.total_sm_size ->
          next_offset = current_offset || logical_address

          if next_offset == logical_address do
            {:cont, {:ok, next_offset}}
          else
            {:halt, :error}
          end

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, logical_address} when is_integer(logical_address) -> {:ok, logical_address}
      _ -> :error
    end
  end

  @doc "Return the current ESM state atom."
  @spec state(atom()) :: atom() | {:error, :not_found}
  def state(slave_name), do: safe_call(slave_name, :state)

  @doc "Return the identity map from SII EEPROM, or nil if not yet read."
  @spec identity(atom()) :: map() | nil | {:error, :not_found}
  def identity(slave_name), do: safe_call(slave_name, :identity)

  @doc "Return the last AL status code, or nil."
  @spec error(atom()) :: non_neg_integer() | nil | {:error, :not_found}
  def error(slave_name), do: safe_call(slave_name, :error)

  @doc """
  Return a diagnostic snapshot for the slave.

  Keys:
    - `:name` — slave atom name
    - `:station` — assigned bus station address
    - `:al_state` — current ESM state: `:init | :preop | :safeop | :op`
    - `:identity` — `%{vendor_id, product_code, revision, serial_number}` from SII, or `nil`
    - `:esc` — `%{fmmu_count, sm_count}` from ESC base registers, or `nil`
    - `:driver` — driver module in use
    - `:coe` — `true` if the slave has a mailbox (CoE-capable)
    - `:available_fmmus` — FMMUs supported by the ESC, or `nil`
    - `:used_fmmus` — count of active `{domain, SyncManager}` attachments
    - `:attachments` — list of `%{domain, sm_index, direction, logical_address, sm_size, signal_count, signals}`
    - `:signals` — list of `%{name, domain, direction, bit_offset, bit_size}` for registered signals
    - `:configuration_error` — last configuration failure atom, or `nil`
  """
  @spec info(atom()) :: {:ok, map()} | {:error, :not_found}
  def info(slave_name), do: safe_call(slave_name, :info)

  @doc """
  Read the decoded input value for an input signal together with its last update
  time. Equivalent to the value delivered via `subscribe/3` for normal
  process-data signals, but with freshness metadata.

  Returns `{:error, :not_ready}` until the first domain cycle completes.
  """
  @spec read_input(atom(), atom()) ::
          {:ok, %{value: term(), updated_at_us: integer() | nil}} | {:error, term()}
  def read_input(slave_name, signal_name) do
    safe_call(slave_name, {:read_input, signal_name})
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
    safe_call(slave_name, {:download_sdo, index, subindex, data})
  end

  @doc """
  Upload a CoE SDO value via the mailbox SyncManagers.

  This is a blocking mailbox transaction. It requires the slave mailbox to be
  configured, so it is only valid from PREOP onward.
  """
  @spec upload_sdo(atom(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def upload_sdo(slave_name, index, subindex) do
    safe_call(slave_name, {:upload_sdo, index, subindex})
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
    sync_config = Keyword.get(opts, :sync)
    health_poll_ms = Keyword.get(opts, :health_poll_ms)

    data = %__MODULE__{
      bus: bus,
      station: station,
      name: name,
      driver: driver,
      config: config,
      configuration_error: nil,
      esc_info: nil,
      dc_cycle_ns: dc_cycle_ns,
      sync_config: sync_config,
      mailbox_counter: 0,
      sii_sm_configs: [],
      sii_pdo_configs: [],
      process_data_request: process_data_request,
      latch_names: %{},
      active_latches: nil,
      latch_poll_ms: nil,
      health_poll_ms: health_poll_ms,
      reconnect_ready?: false,
      signal_registrations: %{},
      signal_registrations_by_sm: %{},
      output_domain_ids_by_sm: %{},
      output_sm_images: %{},
      subscriptions: %{},
      subscriber_refs: %{}
    }

    initialize_to_preop(data)
  end

  # -- State enter -----------------------------------------------------------

  @impl true
  def handle_event(:enter, _old, :init, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :preop, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :safeop, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :op, data) do
    actions = []

    actions =
      if data.latch_poll_ms do
        [{:state_timeout, data.latch_poll_ms, :latch_poll} | actions]
      else
        actions
      end

    actions =
      case data.health_poll_ms do
        ms when is_integer(ms) and ms > 0 ->
          [Health.health_poll_action(ms) | actions]

        _ ->
          actions
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

  def handle_event({:call, from}, :info, state, data) do
    signals =
      case data.signal_registrations do
        nil ->
          []

        regs ->
          regs
          |> Enum.map(fn {name, reg} ->
            %{
              name: name,
              domain: reg.domain_id,
              direction: reg.direction,
              sm_index: elem(reg.sm_key, 1),
              bit_offset: reg.bit_offset,
              bit_size: reg.bit_size
            }
          end)
          |> Enum.sort_by(&{&1.sm_index, &1.bit_offset})
      end

    attachments = Signals.attachment_summaries(data.signal_registrations)

    info = %{
      name: data.name,
      station: data.station,
      al_state: state,
      identity: data.identity,
      esc: data.esc_info,
      driver: data.driver,
      coe: match?(%{recv_size: n} when n > 0, data.mailbox_config),
      available_fmmus: data.esc_info && data.esc_info.fmmu_count,
      used_fmmus: length(attachments),
      attachments: attachments,
      signals: signals,
      configuration_error: data.configuration_error
    }

    {:keep_state_and_data, [{:reply, from, {:ok, info}}]}
  end

  def handle_event({:call, from}, {:request, target}, state, _data) when state == target do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :authorize_reconnect, :down, %{reconnect_ready?: true} = data) do
    reconnect_data = %{data | reconnect_ready?: false}

    case initialize_to_preop(reconnect_data) do
      {:ok, next_state, new_data} ->
        {:next_state, next_state, %{new_data | reconnect_ready?: false}, [{:reply, from, :ok}]}

      {:ok, next_state, new_data, actions} ->
        {:next_state, next_state, %{new_data | reconnect_ready?: false},
         [{:reply, from, :ok} | actions]}
    end
  end

  def handle_event({:call, from}, :authorize_reconnect, :down, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_reconnected}}]}
  end

  def handle_event({:call, from}, :authorize_reconnect, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_down}}]}
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
    {:keep_state, Signals.subscribe_pid(data, signal_name, pid), [{:reply, from, :ok}]}
  end

  # -- Set output ------------------------------------------------------------

  def handle_event({:call, from}, {:write_output, signal_name, value}, _state, data) do
    case Map.get(data.signal_registrations, signal_name) do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, {:not_registered, signal_name}}}]}

      %{direction: :input} ->
        {:keep_state_and_data, [{:reply, from, {:error, {:not_output, signal_name}}}]}

      %{
        domain_id: domain_id,
        sm_key: sm_key,
        bit_offset: bit_offset,
        bit_size: bit_size,
        sm_size: sm_size,
        direction: :output
      } ->
        encoded = data.driver.encode_signal(signal_name, data.config, value)
        domain_ids = Map.get(data.output_domain_ids_by_sm || %{}, sm_key, [domain_id])

        result =
          with {:ok, current} <-
                 ProcessData.current_output_sm_image(data, domain_id, sm_key, sm_size) do
            next_value = set_sm_bits(current, bit_offset, bit_size, encoded)

            case ProcessData.stage_output_sm_image(data, sm_key, domain_ids, next_value) do
              :ok ->
                {:ok, Map.put(data.output_sm_images, sm_key, next_value)}

              {:error, _} = err ->
                err
            end
          end

        case result do
          {:ok, next_output_sm_images} ->
            {:keep_state, %{data | output_sm_images: next_output_sm_images},
             [{:reply, from, :ok}]}

          {:error, reason} ->
            {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
        end
    end
  end

  # -- Read input ------------------------------------------------------------

  def handle_event({:call, from}, {:read_input, signal_name}, _state, data) do
    {:keep_state_and_data, [{:reply, from, Signals.read_input(data, signal_name)}]}
  end

  def handle_event({:call, from}, {:download_sdo, index, subindex, sdo_data}, state, data)
      when state in [:preop, :safeop, :op] do
    case Mailbox.download_sdo(data, index, subindex, sdo_data) do
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
    case Mailbox.upload_sdo(data, index, subindex) do
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

  # SM-grouped key: {domain_id, {:sm, idx}} — unpack per-signal bits and dispatch.
  def handle_event(
        :info,
        {:domain_input, domain_id, {_slave_name, {:sm, _} = sm_key}, old_sm_bytes, new_sm_bytes},
        _state,
        data
      ) do
    Signals.dispatch_domain_input(data, domain_id, sm_key, old_sm_bytes, new_sm_bytes)
    :keep_state_and_data
  end

  def handle_event(:info, {:DOWN, ref, :process, pid, _reason}, _state, data) do
    case Map.get(data.subscriber_refs, pid) do
      ^ref ->
        {:keep_state, Signals.drop_subscriber(data, pid)}

      _ ->
        :keep_state_and_data
    end
  end

  def handle_event(:state_timeout, :latch_poll, :op, data) do
    DCSignals.poll_latches(data)

    actions =
      if data.latch_poll_ms do
        [{:state_timeout, data.latch_poll_ms, :latch_poll}]
      else
        []
      end

    {:keep_state_and_data, actions}
  end

  # -- AL Status health poll (background check per spec §20.4) ---------------

  def handle_event({:timeout, :health_poll}, nil, :op, data) do
    Health.poll_op(data, transition_to: &transition_to/2)
  end

  # -- :down state (slave physically disconnected, polling for reconnect) -----

  def handle_event(:enter, _old, :down, data) do
    Logger.info(
      "[Slave #{data.name}] entering :down — reconnect poll every #{data.health_poll_ms}ms"
    )

    {:keep_state, %{data | reconnect_ready?: false},
     [{{:timeout, :health_poll}, data.health_poll_ms, nil}]}
  end

  def handle_event({:timeout, :health_poll}, nil, :down, %{reconnect_ready?: false} = data) do
    Health.probe_reconnect(data)
  end

  def handle_event({:timeout, :health_poll}, nil, :down, %{reconnect_ready?: true} = data) do
    Health.confirm_reconnect(data)
  end

  # -- Catch-all -------------------------------------------------------------

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # -- Auto-advance helper (called from gen_statem init/1 and retry handler) -

  # Returns a gen_statem init tuple: {:ok, state, data} or {:ok, state, data, actions}.
  # Reads SII EEPROM, arms mailbox SMs, and requests PREOP from the ESC.
  # Full PREOP setup (SDO config, FMMU registration, :slave_ready) runs
  # explicitly after the PREOP transition succeeds.
  defp initialize_to_preop(data) do
    Bootstrap.initialize_to_preop(
      data,
      auto_advance_retry_ms: @auto_advance_retry_ms,
      transition: &transition_to/2
    )
  end

  # -- PREOP configuration (called from :preop enter) -----------------------

  defp configure_preop_process_data(%{driver: nil} = data) do
    ProcessData.configure_preop(data, run_mailbox_config: &Mailbox.run_preop_config/1)
  end

  defp configure_preop_process_data(data) do
    invoke_driver(data, :on_preop)
    ProcessData.configure_preop(data, run_mailbox_config: &Mailbox.run_preop_config/1)
  end

  defp maybe_reconfigure_preop(%{signal_registrations: registrations} = data, opts)
       when map_size(registrations) > 0 do
    requested_driver = Keyword.get(opts, :driver, data.driver)
    requested_config = Keyword.get(opts, :config, data.config)
    requested_process_data = Keyword.get(opts, :process_data, data.process_data_request)
    requested_sync = Keyword.get(opts, :sync, data.sync_config)
    requested_health_poll_ms = Keyword.get(opts, :health_poll_ms, data.health_poll_ms)

    if requested_driver == data.driver and requested_config == data.config and
         requested_process_data == data.process_data_request do
      case apply_sync_only_reconfigure(data, requested_sync) do
        {:ok, new_data} ->
          {:ok, %{new_data | health_poll_ms: requested_health_poll_ms}}

        {:error, reason} ->
          {:error, reason, data}
      end
    else
      {:error, :already_configured, data}
    end
  end

  defp maybe_reconfigure_preop(data, opts) do
    updated_data = %{
      data
      | driver: Keyword.get(opts, :driver, data.driver),
        config: Keyword.get(opts, :config, data.config),
        process_data_request: Keyword.get(opts, :process_data, data.process_data_request),
        sync_config: Keyword.get(opts, :sync, data.sync_config),
        health_poll_ms: Keyword.get(opts, :health_poll_ms, data.health_poll_ms)
    }

    configured = configure_preop_process_data(updated_data)

    case configured.configuration_error do
      nil -> {:ok, configured}
      reason -> {:error, reason, configured}
    end
  end

  defp apply_sync_only_reconfigure(data, requested_sync)
       when requested_sync == data.sync_config do
    {:ok, data}
  end

  defp apply_sync_only_reconfigure(data, requested_sync) do
    updated_data = %{data | sync_config: requested_sync}

    case Mailbox.run_sync_config(updated_data) do
      {:ok, _mailbox_data} ->
        {:ok, updated_data}

      {:error, reason} ->
        ProcessData.log_configuration_error(updated_data, reason)
        {:error, reason}
    end
  end

  # -- Transition helpers ----------------------------------------------------

  defp walk_path(data, steps), do: Transition.walk_path(data, steps, transition_opts())

  defp transition_to(data, target), do: Transition.transition_to(data, target, transition_opts())

  defp post_transition(:preop, data) do
    new_data = configure_preop_process_data(data)

    Logger.debug(
      "[Slave #{data.name}] preop: ready (#{map_size(new_data.signal_registrations)} signal(s) registered)"
    )

    send(EtherCAT.Master, {:slave_ready, data.name, :preop})
    {:ok, new_data}
  end

  defp post_transition(:safeop, data) do
    invoke_driver(data, :on_safeop)
    DCSignals.configure(data)
  end

  defp post_transition(:op, data) do
    invoke_driver(data, :on_op)
    {:ok, data}
  end

  defp post_transition(_target, data), do: {:ok, data}

  defp transition_opts do
    [
      al_codes: @al_codes,
      poll_limit: @poll_limit,
      poll_interval_ms: @poll_interval_ms,
      post_transition: &post_transition/2
    ]
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

  # -- Bit-level SM packing helpers ------------------------------------------

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

  # -- Registry helpers -------------------------------------------------------

  defp safe_call(slave_name, msg) do
    try do
      :gen_statem.call(via(slave_name), msg)
    catch
      :exit, {:noproc, _} -> {:error, :not_found}
    end
  end

  defp via(slave_name), do: {:via, Registry, {EtherCAT.Registry, {:slave, slave_name}}}
end
