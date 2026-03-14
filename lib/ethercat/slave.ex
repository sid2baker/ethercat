defmodule EtherCAT.Slave do
  @moduledoc File.read!(Path.join(__DIR__, "slave.md"))

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.Slave.Runtime.Bootstrap
  alias EtherCAT.Slave.Runtime.Calls
  alias EtherCAT.Slave.Runtime.Configuration
  alias EtherCAT.Slave.Runtime.DCSignals
  alias EtherCAT.Slave.Runtime.Health
  alias EtherCAT.Slave.Runtime.Polling
  alias EtherCAT.Slave.Runtime.Signals
  alias EtherCAT.Slave.Runtime.State
  alias EtherCAT.Slave.Runtime.Transition

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
    # startup retry phase for bootstrap-time observability
    startup_retry_phase: nil,
    # consecutive retries for the current startup retry phase
    startup_retry_count: 0,
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

  # -- :gen_statem callbacks -------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    Logger.metadata(
      component: :slave,
      slave: Keyword.fetch!(opts, :name),
      station: Keyword.fetch!(opts, :station)
    )

    opts
    |> State.new()
    |> initialize_to_preop()
  end

  # -- State enter -----------------------------------------------------------

  @impl true
  def handle_event(:enter, _old, :init, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :preop, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :safeop, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :op, data) do
    {:keep_state_and_data, Polling.op_enter_actions(data)}
  end

  def handle_event(:enter, _old, :bootstrap, _data), do: :keep_state_and_data

  # -- Spec init → preop sequence -------------------------------------------

  @auto_advance_retry_ms 200

  def handle_event({:timeout, :auto_advance}, nil, :init, data) do
    case initialize_to_preop(data) do
      {:ok, :init, new_data, actions} -> {:keep_state, new_data, actions}
      {:ok, :preop, new_data, []} -> {:next_state, :preop, new_data}
      {:ok, next_state, new_data, actions} -> {:next_state, next_state, new_data, actions}
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
    {:keep_state_and_data, Polling.reschedule_latch_poll(poll_ms)}
  end

  # -- AL Status health poll (background check per spec §20.4) ---------------

  def handle_event({:timeout, :health_poll}, nil, :op, data) do
    Health.poll_op(data, transition_to: &transition_to/2, op_code: @al_codes.op)
  end

  # -- :down state (slave physically disconnected, polling for reconnect) -----

  def handle_event(:enter, _old, :down, data) do
    Logger.info(
      "[Slave #{data.name}] entering :down — reconnect poll every #{data.health_poll_ms}ms",
      component: :slave,
      slave: data.name,
      station: data.station,
      event: :down_entered,
      health_poll_ms: data.health_poll_ms
    )

    {:keep_state, %{data | reconnect_ready?: false}, Polling.down_enter_actions(data)}
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

  # Returns a normalized init result tuple: {:ok, state, data, actions}.
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
end
