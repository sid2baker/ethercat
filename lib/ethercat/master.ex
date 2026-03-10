defmodule EtherCAT.Master do
  @moduledoc File.read!(Path.join(__DIR__, "master.md"))

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.{Bus, Telemetry}
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Master.Activation
  alias EtherCAT.Master.Calls
  alias EtherCAT.Master.Config
  alias EtherCAT.Master.Preop
  alias EtherCAT.Master.Recovery
  alias EtherCAT.Master.Session
  alias EtherCAT.Master.Startup
  alias EtherCAT.Master.Status
  alias EtherCAT.Slave.ESC.Registers

  @base_station 0x1000

  # Discovering: poll interval and stability window (ms)
  # Awaiting PREOP: 30 s to receive :preop notifications from all slaves
  @awaiting_preop_timeout_ms 30_000

  @retry_ms 1_000
  @operational :operational

  defstruct [
    :bus_ref,
    :dc_ref,
    # station address of the DC reference clock slave (nil if no DC)
    :dc_ref_station,
    :dc_stations,
    :domain_configs,
    :slave_configs,
    :dc_config,
    :frame_timeout_override_ms,
    :scan_poll_ms,
    :scan_stable_ms,
    base_station: @base_station,
    activatable_slaves: [],
    slaves: [],
    # [{monotonic_ms, count}] — sliding window for scan stability
    scan_window: [],
    slave_count: nil,
    # MapSet of slave names still waiting to report :preop
    pending_preop: MapSet.new(),
    # %{slave_name => reason} for startup activation blockers
    activation_failures: %{},
    # %{fault_key => reason} for critical runtime degradations that block healthy cyclic runtime
    runtime_faults: %{},
    # %{slave_name => reason} for non-critical slave-local faults tracked independently of master state
    slave_faults: %{},
    # last terminal session failure retained after returning to :idle
    last_failure: nil,
    # blocked await_running callers — replied when a usable session state is entered
    await_callers: [],
    # blocked await_operational callers — replied when cyclic operation is live
    await_operational_callers: [],
    # %{monitor_ref => domain_id} — crash detection for running domains
    domain_refs: %{},
    # %{monitor_ref => slave_name} — crash detection for running slaves
    slave_refs: %{}
  ]

  # -- child_spec / start_link -----------------------------------------------

  @doc false
  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]},
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc false
  def start_link(_arg) do
    :gen_statem.start_link({:local, __MODULE__}, __MODULE__, %__MODULE__{}, [])
  end

  # -- :gen_statem callbacks -------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(data), do: {:ok, :idle, data}

  # Session idle -------------------------------------------------------------

  @impl true
  def handle_event(:enter, _old, :idle, _data), do: :keep_state_and_data

  def handle_event({:call, from}, {:start, opts}, :idle, data) do
    with {:ok, start_config} <- normalize_start_options(opts),
         {:ok, bus_pid} <- start_session_bus(start_config.bus_opts) do
      bus_ref = Process.monitor(bus_pid)

      new_data = %{
        data
        | bus_ref: bus_ref,
          dc_ref: nil,
          base_station: start_config.base_station,
          dc_stations: [],
          slave_configs: start_config.slave_config,
          domain_configs: start_config.domain_config,
          dc_config: start_config.dc_config,
          frame_timeout_override_ms: start_config.frame_timeout_override_ms,
          scan_poll_ms: start_config.scan_poll_ms,
          scan_stable_ms: start_config.scan_stable_ms,
          activatable_slaves: [],
          slaves: [],
          scan_window: [],
          pending_preop: MapSet.new(),
          activation_failures: %{},
          runtime_faults: %{},
          slave_faults: %{},
          last_failure: nil,
          await_callers: [],
          await_operational_callers: []
      }

      {:next_state, :discovering, new_data, [{:reply, from, :ok}]}
    else
      {:error, _} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def handle_event({:call, from}, {:start, _}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_started}}]}
  end

  def handle_event({:call, from}, :last_failure, :idle, data) do
    {:keep_state_and_data, [{:reply, from, data.last_failure}]}
  end

  def handle_event({:call, from}, :state, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, :idle}]}
  end

  def handle_event({:call, from}, :await_running, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_started}}]}
  end

  def handle_event({:call, from}, :await_operational, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_started}}]}
  end

  def handle_event({:call, from}, :dc_status, :idle, data) do
    {:keep_state_and_data, [{:reply, from, Status.dc_status(data)}]}
  end

  def handle_event({:call, from}, :reference_clock, :idle, data) do
    {:keep_state_and_data, [{:reply, from, Status.reference_clock_reply(Status.dc_status(data))}]}
  end

  def handle_event({:call, from}, :dc_runtime, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_started}}]}
  end

  def handle_event({:call, from}, :stop, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, :already_stopped}]}
  end

  def handle_event({:call, from}, _event, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_started}}]}
  end

  # Discovery and initialization --------------------------------------------

  def handle_event(:enter, _old, :discovering, _data) do
    {:keep_state_and_data, [{{:timeout, :scan_poll}, 0, nil}]}
  end

  def handle_event({:timeout, :scan_poll}, nil, :discovering, data) do
    now_ms = System.monotonic_time(:millisecond)

    new_window =
      case Bus.transaction(Bus, Transaction.brd(Registers.esc_type())) do
        {:ok, [%{wkc: n}]} ->
          # Prepend new reading; keep enough history to measure a full stable span
          window = [{now_ms, n} | data.scan_window]

          Enum.filter(window, fn {t, _} ->
            now_ms - t <= data.scan_stable_ms + data.scan_poll_ms
          end)

        _ ->
          # Failed transaction resets the window
          []
      end

    if stable?(new_window, now_ms, data.scan_stable_ms) do
      [{_, slave_count} | _] = new_window
      Startup.tune_bus_frame_timeout(data, slave_count)
      Logger.info("[Master] bus stable — #{slave_count} slave(s)")
      config_data = %{data | scan_window: [], slave_count: slave_count}

      case Startup.configure_network(config_data) do
        {:ok, configured} ->
          if MapSet.size(configured.pending_preop) == 0 do
            Logger.info("[Master] all slaves in :preop — activating")

            case Activation.activate_network(configured) do
              {:ok, next_state, active_data} ->
                {:next_state, next_state, active_data}

              {:activation_blocked, blocked_data} ->
                {:next_state, :activation_blocked, blocked_data}

              {:error, reason, failed_data} ->
                Logger.error("[Master] activation failed: #{inspect(reason)}")
                stop_session(failed_data)

                reply_await_callers(
                  failed_data.await_callers,
                  {:error, {:activation_failed, reason}}
                )

                reply_await_callers(
                  failed_data.await_operational_callers,
                  {:error, {:activation_failed, reason}}
                )

                {:next_state, :idle, reset_master(failure_snapshot(:activation_failed, reason))}
            end
          else
            {:next_state, :awaiting_preop, configured}
          end

        {:error, reason, failed_data} ->
          Logger.error("[Master] configuration failed: #{inspect(reason)}")
          stop_session(failed_data)

          reply_await_callers(
            failed_data.await_callers,
            {:error, {:configuration_failed, reason}}
          )

          reply_await_callers(
            failed_data.await_operational_callers,
            {:error, {:configuration_failed, reason}}
          )

          {:next_state, :idle, reset_master(failure_snapshot(:configuration_failed, reason))}
      end
    else
      {:keep_state, %{data | scan_window: new_window},
       [{{:timeout, :scan_poll}, data.scan_poll_ms, nil}]}
    end
  end

  def handle_event({:call, from}, :stop, :discovering, data) do
    stop_session(data)
    reply_await_callers(data.await_callers, {:error, :stopped})
    reply_await_callers(data.await_operational_callers, {:error, :stopped})
    {:next_state, :idle, reset_master(data.last_failure), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, :discovering, data) do
    {:keep_state, %{data | await_callers: [from | data.await_callers]}}
  end

  def handle_event({:call, from}, :await_operational, :discovering, data) do
    {:keep_state, %{data | await_operational_callers: [from | data.await_operational_callers]}}
  end

  # Configuration sequence (Init -> Pre-Op) ---------------------------------

  def handle_event(:enter, _old, :awaiting_preop, _data) do
    {:keep_state_and_data, [{{:timeout, :awaiting_preop}, @awaiting_preop_timeout_ms, nil}]}
  end

  def handle_event(:info, {:slave_ready, name, :preop}, :awaiting_preop, data) do
    new_pending = MapSet.delete(data.pending_preop, name)
    Logger.debug("[Master] slave #{inspect(name)} reached :preop")

    if MapSet.size(new_pending) == 0 do
      Logger.info("[Master] all slaves in :preop — activating")

      case Activation.activate_network(%{data | pending_preop: new_pending}) do
        {:ok, next_state, active_data} ->
          {:next_state, next_state, active_data, [{{:timeout, :awaiting_preop}, :cancel}]}

        {:activation_blocked, blocked_data} ->
          {:next_state, :activation_blocked, blocked_data,
           [{{:timeout, :awaiting_preop}, :cancel}]}

        {:error, reason, failed_data} ->
          Logger.error("[Master] activation failed: #{inspect(reason)}")
          stop_session(failed_data)

          reply_await_callers(
            failed_data.await_callers,
            {:error, {:activation_failed, reason}}
          )

          reply_await_callers(
            failed_data.await_operational_callers,
            {:error, {:activation_failed, reason}}
          )

          {:next_state, :idle, reset_master(failure_snapshot(:activation_failed, reason)),
           [{{:timeout, :awaiting_preop}, :cancel}]}
      end
    else
      {:keep_state, %{data | pending_preop: new_pending}}
    end
  end

  def handle_event({:timeout, :awaiting_preop}, nil, :awaiting_preop, data) do
    remaining = MapSet.to_list(data.pending_preop)
    Logger.error("[Master] awaiting PREOP timed out; slaves not in :preop: #{inspect(remaining)}")
    stop_session(data)
    reply_await_callers(data.await_callers, {:error, :awaiting_preop_timeout})
    reply_await_callers(data.await_operational_callers, {:error, :awaiting_preop_timeout})
    {:next_state, :idle, reset_master(failure_snapshot(:awaiting_preop_timeout, remaining))}
  end

  def handle_event({:call, from}, :stop, :awaiting_preop, data) do
    stop_session(data)
    reply_await_callers(data.await_callers, {:error, :stopped})
    reply_await_callers(data.await_operational_callers, {:error, :stopped})
    {:next_state, :idle, reset_master(data.last_failure), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, :awaiting_preop, data) do
    {:keep_state, %{data | await_callers: [from | data.await_callers]}}
  end

  def handle_event({:call, from}, :await_operational, :awaiting_preop, data) do
    {:keep_state, %{data | await_operational_callers: [from | data.await_operational_callers]}}
  end

  # Activation and cyclic start (Pre-Op -> Safe-Op -> Op) -------------------

  def handle_event(:enter, _old, :preop_ready, data) do
    Logger.info("[Master] running — slaves ready in PREOP, waiting for explicit activate/0")
    reply_await_callers(data.await_callers, :ok)
    {:keep_state, %{data | await_callers: []}}
  end

  def handle_event(:enter, _old, :operational, data) do
    Logger.info("[Master] running")
    reply_await_callers(data.await_callers, :ok)
    reply_await_callers(data.await_operational_callers, :ok)
    updated = %{data | await_callers: [], await_operational_callers: []}
    {:keep_state, updated, slave_fault_retry_actions(updated)}
  end

  def handle_event({:call, from}, :stop, state, data)
      when state in [:preop_ready, :operational] do
    stop_session(data)
    reply_await_callers(data.await_operational_callers, {:error, :stopped})
    {:next_state, :idle, reset_master(data.last_failure), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, state, _data)
      when state in [:preop_ready, :operational] do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_operational, :operational, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event({:timeout, :slave_fault_retry}, nil, :operational, data) do
    retried_data = Recovery.retry_slave_faults(data)
    {:keep_state, retried_data, slave_fault_retry_actions(retried_data)}
  end

  def handle_event({:call, from}, :await_operational, :preop_ready, data) do
    {:keep_state, %{data | await_operational_callers: [from | data.await_operational_callers]}}
  end

  def handle_event(
        {:call, from},
        {:configure_slave, _slave_name, _spec},
        :operational,
        _data
      ) do
    {:keep_state_and_data, [{:reply, from, {:error, :activation_already_started}}]}
  end

  def handle_event(
        {:call, from},
        {:configure_slave, slave_name, spec},
        :preop_ready,
        data
      ) do
    case Preop.configure_discovered_slave(data, slave_name, spec) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, :activate, :operational, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_activated}}]}
  end

  def handle_event({:call, from}, :activate, :preop_ready, data) do
    case Activation.activate_network(data) do
      {:ok, next_state, active_data} ->
        reply_await_callers(active_data.await_operational_callers, :ok)

        {:next_state, next_state, %{active_data | await_operational_callers: []},
         [{:reply, from, :ok}]}

      {:activation_blocked, blocked_data} ->
        {:next_state, :activation_blocked, blocked_data, [{:reply, from, :ok}]}

      {:error, reason, _failed_data} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  # Activation blocked -------------------------------------------------------

  def handle_event(:enter, _old, :activation_blocked, data) do
    Logger.warning("[Master] activation blocked — #{Status.activation_blocked_summary(data)}")

    reply_await_callers(data.await_callers, Status.activation_blocked_reply(data))
    reply_await_callers(data.await_operational_callers, Status.activation_blocked_reply(data))

    {:keep_state, %{data | await_callers: [], await_operational_callers: []},
     [{{:timeout, :retry}, @retry_ms, nil}]}
  end

  def handle_event({:timeout, :retry}, nil, :activation_blocked, data) do
    case Recovery.retry_activation_blocked_state(data) do
      {:ok, next_state, healed_data} ->
        {:next_state, next_state, healed_data}

      {:activation_blocked, still_blocked} ->
        {:keep_state, still_blocked, [{{:timeout, :retry}, @retry_ms, nil}]}

      {:recovering, still_recovering} ->
        {:next_state, :recovering, still_recovering, [{{:timeout, :retry}, @retry_ms, nil}]}
    end
  end

  def handle_event({:call, from}, :stop, :activation_blocked, data) do
    stop_session(data)
    reply_await_callers(data.await_operational_callers, {:error, :stopped})
    {:next_state, :idle, reset_master(data.last_failure), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, :activation_blocked, data) do
    {:keep_state_and_data, [{:reply, from, Status.activation_blocked_reply(data)}]}
  end

  def handle_event({:call, from}, :await_operational, :activation_blocked, data) do
    {:keep_state_and_data, [{:reply, from, Status.activation_blocked_reply(data)}]}
  end

  def handle_event(
        {:call, from},
        {:configure_slave, _slave_name, _spec},
        :activation_blocked,
        _data
      ) do
    {:keep_state_and_data, [{:reply, from, {:error, :activation_in_progress}}]}
  end

  def handle_event({:call, from}, :activate, :activation_blocked, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :activation_in_progress}}]}
  end

  def handle_event(:info, {:slave_reconnected, name}, :activation_blocked, data) do
    case Recovery.authorize_activation_reconnect(data, name) do
      {:ok, updated} ->
        {:keep_state, updated, [{{:timeout, :retry}, @retry_ms, nil}]}

      {:error, updated} ->
        {:keep_state, updated, [{{:timeout, :retry}, @retry_ms, nil}]}

      :ignore ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:slave_ready, name, :preop}, :activation_blocked, data) do
    case Recovery.handle_activation_ready_preop(data, name) do
      {:ok, next_state, healed_data} ->
        {:next_state, next_state, healed_data}

      {:activation_blocked, still_blocked} ->
        {:keep_state, still_blocked, [{{:timeout, :retry}, @retry_ms, nil}]}

      {:recovering, still_recovering} ->
        {:next_state, :recovering, still_recovering, [{{:timeout, :retry}, @retry_ms, nil}]}

      :ignore ->
        :keep_state_and_data
    end
  end

  # Continuous loop recovery -------------------------------------------------

  def handle_event(:enter, _old, :recovering, data) do
    Logger.warning("[Master] recovering — #{Status.recovering_summary(data)}")

    reply_await_callers(data.await_callers, Status.recovering_reply(data))
    reply_await_callers(data.await_operational_callers, Status.recovering_reply(data))

    {:keep_state, %{data | await_callers: [], await_operational_callers: []},
     [{{:timeout, :retry}, @retry_ms, nil}]}
  end

  def handle_event({:timeout, :retry}, nil, :recovering, data) do
    case Recovery.retry_recovering_state(data) do
      {:ok, next_state, healed_data} ->
        {:next_state, next_state, healed_data}

      {:recovering, still_recovering} ->
        case Recovery.unrecoverable_recovery_reason(still_recovering) do
          nil ->
            {:keep_state, still_recovering, [{{:timeout, :retry}, @retry_ms, nil}]}

          reason ->
            Logger.error("[Master] recovery failed and requires full restart: #{inspect(reason)}")

            stop_session(still_recovering)

            {:next_state, :idle, reset_master(failure_snapshot(:recovery_unrecoverable, reason))}
        end
    end
  end

  def handle_event({:call, from}, :stop, :recovering, data) do
    stop_session(data)
    reply_await_callers(data.await_operational_callers, {:error, :stopped})
    {:next_state, :idle, reset_master(data.last_failure), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, :recovering, data) do
    {:keep_state_and_data, [{:reply, from, Status.recovering_reply(data)}]}
  end

  def handle_event({:call, from}, :await_operational, :recovering, data) do
    {:keep_state_and_data, [{:reply, from, Status.recovering_reply(data)}]}
  end

  def handle_event({:call, from}, {:configure_slave, _slave_name, _spec}, :recovering, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :recovery_in_progress}}]}
  end

  def handle_event({:call, from}, :activate, :recovering, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :recovery_in_progress}}]}
  end

  # -- Shared active-state calls ---------------------------------------------

  def handle_event({:call, from}, event, state, data)
      when state in [
             :discovering,
             :awaiting_preop,
             :preop_ready,
             :operational,
             :activation_blocked,
             :recovering
           ] do
    Calls.handle_active(from, event, state, data)
  end

  # Bus crashed — clean up and return to idle
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, _state, data)
      when ref == data.bus_ref and not is_nil(ref) do
    Logger.error("[Master] bus crashed (#{inspect(reason)}) — returning to idle")
    reply_await_callers(data.await_callers, {:error, {:bus_down, reason}})
    reply_await_callers(data.await_operational_callers, {:error, {:bus_down, reason}})
    stop_session(data)
    {:next_state, :idle, reset_master(failure_snapshot(:bus_down, reason))}
  end

  # Domain process crashed unexpectedly
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, state, data)
      when is_map_key(data.domain_refs, ref) do
    {id, refs} = Map.pop(data.domain_refs, ref)
    Logger.error("[Master] domain #{id} crashed: #{inspect(reason)}")
    Telemetry.domain_crashed(id, reason)

    data_with_refs = %{data | domain_refs: refs}

    recovering_data =
      Recovery.put_runtime_fault(data_with_refs, {:domain, id}, {:crashed, reason})

    Recovery.transition_runtime_fault(state, recovering_data)
  end

  # Slave process crashed unexpectedly
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, state, data)
      when is_map_key(data.slave_refs, ref) do
    {name, refs} = Map.pop(data.slave_refs, ref)
    Logger.error("[Master] slave #{name} crashed: #{inspect(reason)}")
    Telemetry.slave_crashed(name, reason)

    data_with_refs = Map.put(data, :slave_refs, refs)
    track_slave_fault(state, data_with_refs, name, {:crashed, reason})
  end

  # DC runtime crashed unexpectedly
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, state, data)
      when ref == data.dc_ref and not is_nil(ref) do
    Logger.error("[Master] DC runtime crashed: #{inspect(reason)}")

    recovering_data =
      data
      |> Map.put(:dc_ref, nil)
      |> Recovery.put_runtime_fault({:dc, :runtime}, {:crashed, reason})

    Recovery.transition_runtime_fault(state, recovering_data)
  end

  # Stale :DOWN from a previous session — ignore
  def handle_event(:info, {:DOWN, _ref, :process, _pid, _reason}, _state, _data) do
    :keep_state_and_data
  end

  # Domain stopped cycling due to consecutive misses
  def handle_event(:info, {:domain_stopped, id, reason}, state, data) do
    Logger.error("[Master] domain #{id} stopped cycling: #{inspect(reason)}")
    recovering_data = Recovery.put_runtime_fault(data, {:domain, id}, {:stopped, reason})
    Recovery.transition_runtime_fault(state, recovering_data)
  end

  def handle_event(:info, {:domain_cycle_invalid, id, reason}, @operational, data) do
    Logger.warning("[Master] domain #{id} cycle invalid: #{inspect(reason)} — entering recovery")

    {:next_state, :recovering,
     Recovery.put_runtime_fault(data, {:domain, id}, {:cycle_invalid, reason})}
  end

  def handle_event(:info, {:domain_cycle_invalid, id, reason}, :recovering, data) do
    Logger.warning("[Master] domain #{id} cycle still invalid: #{inspect(reason)}")
    {:keep_state, Recovery.put_runtime_fault(data, {:domain, id}, {:cycle_invalid, reason})}
  end

  def handle_event(:info, {:domain_cycle_invalid, _id, _reason}, _state, _data) do
    :keep_state_and_data
  end

  def handle_event(:info, {:domain_cycle_recovered, id}, :recovering, data) do
    Logger.info("[Master] domain #{id} cycle recovered")

    case Recovery.maybe_resume_running(Recovery.clear_runtime_fault(data, {:domain, id})) do
      {:ok, next_state, healed_data} ->
        {:next_state, next_state, healed_data}

      {:recovering, still_recovering} ->
        {:keep_state, still_recovering}
    end
  end

  def handle_event(:info, {:domain_cycle_recovered, _id}, _state, _data) do
    :keep_state_and_data
  end

  # Slave retreated to a lower ESM state (AL fault detected by health poll)
  def handle_event(:info, {:slave_retreated, name, target_state}, @operational, data) do
    Logger.warning("[Master] slave #{name} retreated to #{target_state}")
    track_slave_fault(:operational, data, name, {:retreated, target_state})
  end

  def handle_event(:info, {:slave_retreated, name, target_state}, :recovering, data) do
    Logger.warning("[Master] slave #{name} retreated to #{target_state}")
    track_slave_fault(:recovering, data, name, {:retreated, target_state})
  end

  def handle_event(:info, {:slave_retreated, name, target_state}, _state, _data) do
    Logger.warning("[Master] slave #{name} retreated to #{target_state} (already not running)")
    :keep_state_and_data
  end

  # Slave physically disconnected (health poll wkc=0 or bus error)
  def handle_event(:info, {:slave_down, name}, @operational, data) do
    Logger.warning("[Master] slave #{name} disconnected")
    track_slave_fault(:operational, data, name, {:down, :disconnected})
  end

  def handle_event(:info, {:slave_down, name}, :recovering, data) do
    Logger.warning("[Master] slave #{name} disconnected")
    track_slave_fault(:recovering, data, name, {:down, :disconnected})
  end

  def handle_event(:info, {:slave_reconnected, name}, state, data)
      when state in [:operational, :recovering] do
    updated = Recovery.authorize_runtime_reconnect(data, name)
    keep_state_with_slave_fault_retry(state, updated)
  end

  # Slave reconnected and reached :preop — attempt to bring it back to :op
  def handle_event(:info, {:slave_ready, name, :preop}, state, data)
      when state in [:operational, :recovering] do
    case Recovery.handle_runtime_ready_preop(state, data, name) do
      {:ok, next_state, healed_data} ->
        {:next_state, next_state, healed_data}

      {:keep, updated} ->
        keep_state_with_slave_fault_retry(state, updated)
    end
  end

  def handle_event(:info, {:dc_runtime_failed, reason}, @operational, data) do
    Logger.warning("[Master] DC runtime failed: #{inspect(reason)} — entering recovery")

    {:next_state, :recovering,
     Recovery.put_runtime_fault(data, {:dc, :runtime}, {:failed, reason})}
  end

  def handle_event(:info, {:dc_runtime_failed, reason}, :recovering, data) do
    Logger.warning("[Master] DC runtime still failing: #{inspect(reason)}")
    {:keep_state, Recovery.put_runtime_fault(data, {:dc, :runtime}, {:failed, reason})}
  end

  def handle_event(:info, {:dc_runtime_recovered}, :recovering, data) do
    Logger.info("[Master] DC runtime recovered")

    case Recovery.maybe_resume_running(Recovery.clear_runtime_fault(data, {:dc, :runtime})) do
      {:ok, next_state, healed_data} ->
        {:next_state, next_state, healed_data}

      {:recovering, still_recovering} ->
        {:keep_state, still_recovering}
    end
  end

  def handle_event(
        :info,
        {:dc_lock_lost, lock_state, max_sync_diff_ns},
        @operational,
        data
      )
      when not is_nil(data.dc_config) do
    case Recovery.lock_policy(data) do
      :advisory ->
        Logger.warning(
          "[Master] DC lock lost: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — advisory only"
        )

        :keep_state_and_data

      :recovering ->
        Logger.warning(
          "[Master] DC lock lost: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — entering recovery"
        )

        {:next_state, :recovering,
         Recovery.put_runtime_fault(data, {:dc, :lock}, {lock_state, max_sync_diff_ns})}

      :fatal ->
        Logger.error(
          "[Master] DC lock lost: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — stopping session"
        )

        stop_session(data)

        {:next_state, :idle,
         reset_master(failure_snapshot(:dc_lock_lost, {lock_state, max_sync_diff_ns}))}
    end
  end

  def handle_event(
        :info,
        {:dc_lock_lost, _lock_state, _max_sync_diff_ns},
        @operational,
        _data
      ) do
    :keep_state_and_data
  end

  def handle_event(:info, {:dc_lock_lost, lock_state, max_sync_diff_ns}, :recovering, data)
      when not is_nil(data.dc_config) do
    case Recovery.lock_policy(data) do
      :advisory ->
        Logger.warning(
          "[Master] DC lock lost while recovering: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — advisory only"
        )

        :keep_state_and_data

      :recovering ->
        Logger.warning(
          "[Master] DC lock still lost: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)}"
        )

        {:keep_state,
         Recovery.put_runtime_fault(data, {:dc, :lock}, {lock_state, max_sync_diff_ns})}

      :fatal ->
        Logger.error(
          "[Master] DC lock lost while recovering: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — stopping session"
        )

        stop_session(data)

        {:next_state, :idle,
         reset_master(failure_snapshot(:dc_lock_lost, {lock_state, max_sync_diff_ns}))}
    end
  end

  def handle_event(:info, {:dc_lock_lost, _lock_state, _max_sync_diff_ns}, :recovering, _data) do
    :keep_state_and_data
  end

  def handle_event(:info, {:dc_lock_regained, max_sync_diff_ns}, @operational, data)
      when not is_nil(data.dc_config) do
    case Recovery.lock_policy(data) do
      :advisory ->
        Logger.info("[Master] DC lock regained (max_sync_diff_ns=#{inspect(max_sync_diff_ns)})")
        :keep_state_and_data

      :recovering ->
        :keep_state_and_data

      :fatal ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:dc_lock_regained, _max_sync_diff_ns}, @operational, _data) do
    :keep_state_and_data
  end

  def handle_event(:info, {:dc_lock_regained, max_sync_diff_ns}, :recovering, data)
      when not is_nil(data.dc_config) do
    case Recovery.lock_policy(data) do
      :advisory ->
        Logger.info(
          "[Master] DC lock regained while recovering (max_sync_diff_ns=#{inspect(max_sync_diff_ns)})"
        )

        :keep_state_and_data

      :recovering ->
        Logger.info("[Master] DC lock regained (max_sync_diff_ns=#{inspect(max_sync_diff_ns)})")

        case Recovery.maybe_resume_running(Recovery.clear_runtime_fault(data, {:dc, :lock})) do
          {:ok, next_state, healed_data} ->
            {:next_state, next_state, healed_data}

          {:recovering, still_recovering} ->
            {:keep_state, still_recovering}
        end

      :fatal ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:dc_lock_regained, _max_sync_diff_ns}, :recovering, _data) do
    :keep_state_and_data
  end

  # :slave_ready arriving while not awaiting_preop (e.g. restart race) — ignore
  def handle_event(:info, {:slave_ready, _name, _ready_state}, _state, _data) do
    :keep_state_and_data
  end

  # Catch-all — discard stale timeouts and unexpected messages
  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # -- Scan stability --------------------------------------------------------

  defp stable?([], _now_ms, _scan_stable_ms), do: false

  defp stable?(window, now_ms, scan_stable_ms) do
    counts = Enum.map(window, fn {_, c} -> c end)
    oldest_t = elem(List.last(window), 0)
    span = now_ms - oldest_t

    span >= scan_stable_ms and
      length(counts) >= 2 and
      length(Enum.uniq(counts)) == 1 and
      hd(counts) > 0
  end

  # -- Startup normalization -------------------------------------------------

  defp normalize_start_options(opts), do: Config.normalize_start_options(opts)

  defp start_session_bus(bus_opts) do
    DynamicSupervisor.start_child(
      EtherCAT.SessionSupervisor,
      {Bus, Keyword.put(bus_opts, :name, Bus)}
    )
  end

  defp reset_master(last_failure), do: %__MODULE__{last_failure: last_failure}

  defp track_slave_fault(state, data, name, reason) do
    updated = Recovery.put_slave_fault(data, name, reason)

    if critical_slave_fault?(updated, name, reason) do
      Recovery.transition_runtime_fault(
        state,
        Recovery.put_runtime_fault(updated, {:slave, name}, reason)
      )
    else
      keep_state_with_slave_fault_retry(state, updated)
    end
  end

  defp keep_state_with_slave_fault_retry(:operational, data) do
    {:keep_state, data, slave_fault_retry_actions(data)}
  end

  defp keep_state_with_slave_fault_retry(_state, data) do
    {:keep_state, data}
  end

  defp critical_slave_fault?(data, name, {:down, :disconnected}) do
    slave_participates_in_domains?(data, name)
  end

  defp critical_slave_fault?(_data, _name, _reason), do: false

  defp slave_participates_in_domains?(data, name) do
    case Config.fetch_slave_config(data.slave_configs || [], name) do
      {:ok, slave_config, _idx} ->
        Config.requested_domain_ids(slave_config) != []

      {:error, _reason} ->
        false
    end
  end

  defp slave_fault_retry_actions(data) do
    if Recovery.retryable_slave_faults?(data) do
      [{{:timeout, :slave_fault_retry}, @retry_ms, nil}]
    else
      []
    end
  end

  defp failure_snapshot(kind, reason) do
    %{
      kind: kind,
      reason: reason,
      at_ms: System.system_time(:millisecond)
    }
  end

  # -- Session teardown ------------------------------------------------------

  defp stop_session(data) do
    Session.stop(data)
  end

  defp reply_await_callers(callers, reply) do
    Enum.each(callers, fn from -> :gen_statem.reply(from, reply) end)
  end
end
