defmodule EtherCAT.Slave do
  @moduledoc """
  EtherCAT State Machine (ESM) lifecycle for one physical slave device.

  One Slave process per named slave, registered under `{:slave, name}`.
  Manages INIT → PREOP → SAFEOP → OP transitions, mailbox configuration,
  process-data SM/FMMU setup, and DC signal programming.

  Typically driven by the master — use `EtherCAT.read_input/2`,
  `EtherCAT.write_output/3`, and `EtherCAT.subscribe/2` from the top-level API.
  Direct slave access via `request/2`, `info/1`, and `download_sdo/4` is also supported.

  ## State Transitions

  ```mermaid
  stateDiagram-v2
      state "INIT" as init
      state "BOOTSTRAP" as bootstrap
      state "PREOP" as preop
      state "SAFEOP" as safeop
      state "OP" as op
      state "DOWN" as down
      [*] --> init
      init --> preop: auto-advance succeeds
      init --> init: auto-advance retries
      init --> bootstrap: bootstrap is requested
      init --> safeop: SAFEOP is requested
      init --> op: OP is requested
      bootstrap --> init: INIT is requested
      preop --> safeop: SAFEOP is requested
      preop --> op: OP is requested
      preop --> init: INIT is requested
      safeop --> op: OP is requested
      safeop --> preop: PREOP is requested
      safeop --> init: INIT is requested
      op --> safeop: SAFEOP is requested or AL health retreats
      op --> preop: PREOP is requested
      op --> init: INIT is requested
      op --> down: health poll sees bus loss or zero WKC
      down --> preop: reconnect is authorized and PREOP rebuild succeeds
      down --> init: reconnect retries from INIT
  ```
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.Slave.Bootstrap
  alias EtherCAT.Slave.Calls
  alias EtherCAT.Slave.Configuration
  alias EtherCAT.Slave.DCSignals
  alias EtherCAT.Slave.Health
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
  @transition_opts [
    al_codes: @al_codes,
    poll_limit: @poll_limit,
    poll_interval_ms: @poll_interval_ms,
    post_transition: &Configuration.post_transition/2
  ]

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
  Read the decoded input value for an input signal. Equivalent to the value
  delivered via `subscribe/3` for normal process-data signals.

  Returns `{:error, :not_ready}` until the first domain cycle completes.
  """
  @spec read_input(atom(), atom()) :: {:ok, term()} | {:error, term()}
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
    {:keep_state_and_data, op_enter_actions(data)}
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

  def handle_event({:call, from}, event, state, data) do
    Calls.handle(
      from,
      event,
      state,
      data,
      paths: @paths,
      initialize_to_preop: &initialize_to_preop/1,
      walk_path: &walk_path/2
    )
  end

  # -- Domain input change notification (sent by Domain on cycle) ------------

  # SM-grouped key: {domain_id, {:sm, idx}} — unpack per-signal bits and dispatch.
  def handle_event(
        :info,
        {:domain_inputs, domain_id, changes},
        _state,
        data
      ) do
    Enum.each(changes, fn {{_slave_name, {:sm, _} = sm_key}, old_sm_bytes, new_sm_bytes} ->
      Signals.dispatch_domain_input(data, domain_id, sm_key, old_sm_bytes, new_sm_bytes)
    end)

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

  def handle_event(:state_timeout, :latch_poll, :op, %{latch_poll_ms: poll_ms} = data)
      when is_integer(poll_ms) and poll_ms > 0 do
    DCSignals.poll_latches(data)
    {:keep_state_and_data, [{:state_timeout, poll_ms, :latch_poll}]}
  end

  # -- AL Status health poll (background check per spec §20.4) ---------------

  def handle_event({:timeout, :health_poll}, nil, :op, data) do
    Health.poll_op(data, transition_to: &transition_to/2, op_code: @al_codes.op)
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

  # -- Transition helpers ----------------------------------------------------

  defp walk_path(data, steps), do: Transition.walk_path(data, steps, @transition_opts)

  defp transition_to(data, target), do: Transition.transition_to(data, target, @transition_opts)

  defp op_enter_actions(data) do
    latch_poll_actions(data) ++ health_poll_actions(data)
  end

  defp latch_poll_actions(%{latch_poll_ms: poll_ms}) when is_integer(poll_ms) and poll_ms > 0 do
    [{:state_timeout, poll_ms, :latch_poll}]
  end

  defp latch_poll_actions(_data), do: []

  defp health_poll_actions(%{health_poll_ms: poll_ms})
       when is_integer(poll_ms) and poll_ms > 0 do
    [Health.health_poll_action(poll_ms)]
  end

  defp health_poll_actions(_data), do: []

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
