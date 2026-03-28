defmodule EtherCAT.Master.FSM do
  @moduledoc false

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.{Bus, Telemetry, Utils}
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Master
  alias EtherCAT.Master.Activation
  alias EtherCAT.Master.Calls
  alias EtherCAT.Master.Config
  alias EtherCAT.Master.Deactivation
  alias EtherCAT.Master.Preop
  alias EtherCAT.Master.Recovery
  alias EtherCAT.Master.Session
  alias EtherCAT.Master.Startup
  alias EtherCAT.Master.Status
  alias EtherCAT.Slave.ESC.Registers

  # Discovering: poll interval and stability window (ms)
  # Awaiting PREOP: 30 s to receive :preop notifications from all slaves
  @awaiting_preop_timeout_ms 30_000

  # Final startup mailbox replies can still arrive just after the
  # bus first reports idle. `await_running/1` waits through a short quiet window
  # and drains once more so the first public mailbox call starts from quiescence.
  @await_running_quiet_ms 2
  @retry_ms 1_000
  @operational :operational

  @doc false
  def start_link(_arg) do
    :gen_statem.start_link({:local, Master}, __MODULE__, %Master{}, [])
  end

  # -- :gen_statem callbacks -------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(data) do
    Logger.metadata(component: :master)
    {:ok, :idle, data}
  end

  # Session idle -------------------------------------------------------------

  @impl true
  def handle_event(:enter, old, :idle, data) do
    emit_state_change(old, :idle, data)
    :keep_state_and_data
  end

  def handle_event({:call, from}, {:start, opts}, :idle, data) do
    with {:ok, start_config} <- normalize_start_options(opts),
         {:ok, bus_pid} <- start_session_bus(start_config.bus_opts) do
      bus_ref = Process.monitor(bus_pid)

      new_data = %{
        data
        | bus_ref: bus_ref,
          backend: start_config.backend,
          dc_ref: nil,
          base_station: start_config.base_station,
          dc_stations: [],
          slave_configs: start_config.slave_config,
          domain_configs: start_config.domain_config,
          dc_config: start_config.dc_config,
          frame_timeout_floor_ms: start_config.frame_timeout_floor_ms,
          frame_timeout_override_ms: start_config.frame_timeout_override_ms,
          scan_poll_ms: start_config.scan_poll_ms,
          scan_stable_ms: start_config.scan_stable_ms,
          desired_runtime_target: runtime_target_from_configs(start_config.slave_config),
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

  def handle_event({:call, from}, :status, :idle, data) do
    {:keep_state_and_data, [{:reply, from, Status.from_runtime(:idle, data)}]}
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

  def handle_event(:enter, old, :discovering, data) do
    emit_state_change(old, :discovering, data)
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
      Telemetry.master_startup_bus_stable(slave_count)

      Logger.info(
        "[Master] bus stable — #{slave_count} slave(s)",
        component: :master,
        event: :bus_stable,
        slave_count: slave_count
      )

      config_data = %{data | scan_window: [], slave_count: slave_count}

      case Startup.configure_network(config_data) do
        {:ok, configured} ->
          configured = %{
            configured
            | desired_runtime_target: runtime_target_from_names(configured.activatable_slaves)
          }

          if MapSet.size(configured.pending_preop) == 0 do
            Logger.info(
              "[Master] all slaves in :preop — activating",
              component: :master,
              event: :activation_starting,
              runtime_target: Status.desired_runtime_target(configured)
            )

            case Activation.activate_network(configured) do
              {:ok, next_state, active_data} ->
                {:next_state, next_state, active_data}

              {:activation_blocked, blocked_data} ->
                {:next_state, :activation_blocked, blocked_data}

              {:error, reason, failed_data} ->
                Logger.error(
                  "[Master] activation failed: #{inspect(reason)}",
                  component: :master,
                  event: :activation_failed,
                  reason_kind: Utils.reason_kind(reason)
                )

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
          Logger.error(
            "[Master] configuration failed: #{inspect(reason)}",
            component: :master,
            event: :configuration_failed,
            reason_kind: Utils.reason_kind(reason)
          )

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

  def handle_event(:enter, old, :awaiting_preop, data) do
    emit_state_change(old, :awaiting_preop, data)
    {:keep_state_and_data, [{{:timeout, :awaiting_preop}, @awaiting_preop_timeout_ms, nil}]}
  end

  def handle_event(:info, {:slave_ready, name, :preop}, :awaiting_preop, data) do
    new_pending = MapSet.delete(data.pending_preop, name)

    Logger.debug(
      "[Master] slave #{inspect(name)} reached :preop",
      component: :master,
      event: :slave_preop_ready,
      slave: name,
      pending_count: MapSet.size(new_pending)
    )

    if MapSet.size(new_pending) == 0 do
      Logger.info(
        "[Master] all slaves in :preop — activating",
        component: :master,
        event: :activation_starting,
        runtime_target: Status.desired_runtime_target(data)
      )

      case Activation.activate_network(%{data | pending_preop: new_pending}) do
        {:ok, next_state, active_data} ->
          {:next_state, next_state, active_data, [{{:timeout, :awaiting_preop}, :cancel}]}

        {:activation_blocked, blocked_data} ->
          {:next_state, :activation_blocked, blocked_data,
           [{{:timeout, :awaiting_preop}, :cancel}]}

        {:error, reason, failed_data} ->
          Logger.error(
            "[Master] activation failed: #{inspect(reason)}",
            component: :master,
            event: :activation_failed,
            reason_kind: Utils.reason_kind(reason)
          )

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

    Logger.error(
      "[Master] awaiting PREOP timed out; slaves not in :preop: #{inspect(remaining)}",
      component: :master,
      event: :awaiting_preop_timeout,
      pending_count: length(remaining)
    )

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

  def handle_event(:enter, old, :preop_ready, data) do
    emit_state_change(old, :preop_ready, data)

    Logger.info(
      "[Master] running — slaves ready in PREOP, waiting for explicit activate/0",
      component: :master,
      event: :state_entered,
      public_state: :preop_ready,
      runtime_target: Status.desired_runtime_target(data)
    )

    {:keep_state, reply_running_waiters(data)}
  end

  def handle_event(:enter, old, :deactivated, data) do
    emit_state_change(old, :deactivated, data)

    Logger.info(
      "[Master] deactivated — runtime settled below OP, waiting for activate/0",
      component: :master,
      event: :state_entered,
      public_state: :deactivated,
      runtime_target: Status.desired_runtime_target(data)
    )

    {:keep_state, reply_running_waiters(data)}
  end

  def handle_event(:enter, old, :operational, data) do
    emit_state_change(old, :operational, data)

    Logger.info(
      "[Master] running",
      component: :master,
      event: :state_entered,
      public_state: :operational,
      runtime_target: Status.desired_runtime_target(data)
    )

    reply_await_callers(data.await_callers, :ok)
    reply_await_callers(data.await_operational_callers, :ok)
    updated = %{data | await_callers: [], await_operational_callers: []}
    {:keep_state, updated, slave_fault_retry_actions(updated)}
  end

  def handle_event({:call, from}, :stop, state, data)
      when state in [:preop_ready, :deactivated, :operational] do
    stop_session(data)
    reply_await_callers(data.await_operational_callers, {:error, :stopped})
    {:next_state, :idle, reset_master(data.last_failure), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, state, _data)
      when state in [:preop_ready, :deactivated, :operational] do
    {:keep_state_and_data, [{:reply, from, await_running_reply(state)}]}
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

  def handle_event({:call, from}, :await_operational, :deactivated, data) do
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

  def handle_event(
        {:call, from},
        {:configure_slave, _slave_name, _spec},
        :deactivated,
        _data
      ) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_preop}}]}
  end

  def handle_event({:call, from}, :activate, :operational, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_activated}}]}
  end

  def handle_event({:call, from}, :activate, :preop_ready, data) do
    handle_activate_network(from, %{data | desired_runtime_target: :op})
  end

  def handle_event({:call, from}, :activate, :deactivated, data) do
    handle_activate_network(from, %{data | desired_runtime_target: :op})
  end

  def handle_event({:call, from}, {:deactivate, :preop}, :preop_ready, data) do
    {:keep_state, %{data | desired_runtime_target: :preop}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:deactivate, target}, state, data)
      when state in [:deactivated, :operational, :activation_blocked, :recovering] and
             target in [:safeop, :preop] do
    if deactivated_target_settled?(state, data, target) do
      {:keep_state, %{data | desired_runtime_target: target}, [{:reply, from, :ok}]}
    else
      case Deactivation.deactivate_network(%{data | desired_runtime_target: target}, target) do
        {:ok, next_state, deactivated_data} ->
          {:next_state, next_state, deactivated_data, [{:reply, from, :ok}]}

        {:activation_blocked, blocked_data} ->
          {:next_state, :activation_blocked, blocked_data, [{:reply, from, :ok}]}
      end
    end
  end

  def handle_event({:call, from}, {:deactivate, :safeop}, :preop_ready, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_operational}}]}
  end

  # Activation blocked -------------------------------------------------------

  def handle_event(:enter, old, :activation_blocked, data) do
    emit_state_change(old, :activation_blocked, data)

    Logger.warning(
      "[Master] activation blocked — #{Status.activation_blocked_summary(data)}",
      component: :master,
      event: :activation_blocked_state,
      blocked_count: map_size(data.activation_failures)
    )

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

  def handle_event(:info, {:slave_reconnected, _name}, :activation_blocked, _data),
    do: :keep_state_and_data

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

  def handle_event(:enter, old, :recovering, data) do
    emit_state_change(old, :recovering, data)

    Logger.warning(
      "[Master] recovering — #{Status.recovering_summary(data)}",
      component: :master,
      event: :recovering_state,
      runtime_fault_count: map_size(data.runtime_faults)
    )

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
            Logger.error(
              "[Master] recovery failed and requires full restart: #{inspect(reason)}",
              component: :master,
              event: :recovery_unrecoverable,
              reason_kind: Utils.reason_kind(reason)
            )

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
             :deactivated,
             :operational,
             :activation_blocked,
             :recovering
           ] do
    Calls.handle_active(from, event, state, data)
  end

  # Bus crashed — clean up and return to idle
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, _state, data)
      when ref == data.bus_ref and not is_nil(ref) do
    Logger.error(
      "[Master] bus crashed (#{inspect(reason)}) — returning to idle",
      component: :master,
      event: :bus_crashed,
      reason_kind: Utils.reason_kind(reason)
    )

    reply_await_callers(data.await_callers, {:error, {:bus_down, reason}})
    reply_await_callers(data.await_operational_callers, {:error, {:bus_down, reason}})
    stop_session(data)
    {:next_state, :idle, reset_master(failure_snapshot(:bus_down, reason))}
  end

  # Domain process crashed unexpectedly
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, state, data)
      when is_map_key(data.domain_refs, ref) do
    {id, refs} = Map.pop(data.domain_refs, ref)

    Logger.error(
      "[Master] domain #{id} crashed: #{inspect(reason)}",
      component: :master,
      event: :domain_crashed,
      domain: id,
      reason_kind: Utils.reason_kind(reason)
    )

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

    Logger.error(
      "[Master] slave #{name} crashed: #{inspect(reason)}",
      component: :master,
      event: :slave_crashed,
      slave: name,
      reason_kind: Utils.reason_kind(reason)
    )

    Telemetry.slave_crashed(name, reason)

    data_with_refs = Map.put(data, :slave_refs, refs)
    track_slave_fault(state, data_with_refs, name, {:crashed, reason})
  end

  # DC runtime crashed unexpectedly
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, state, data)
      when ref == data.dc_ref and not is_nil(ref) do
    Logger.error(
      "[Master] DC runtime crashed: #{inspect(reason)}",
      component: :master,
      event: :dc_runtime_crashed,
      reason_kind: Utils.reason_kind(reason)
    )

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
    Logger.error(
      "[Master] domain #{id} stopped cycling: #{inspect(reason)}",
      component: :master,
      event: :domain_stopped,
      domain: id,
      reason_kind: Utils.reason_kind(reason)
    )

    recovering_data = Recovery.put_runtime_fault(data, {:domain, id}, {:stopped, reason})
    Recovery.transition_runtime_fault(state, recovering_data)
  end

  def handle_event(:info, {:domain_cycle_degraded, id, reason, consecutive}, @operational, data) do
    Logger.warning(
      "[Master] domain #{id} cycle degraded after #{consecutive} consecutive invalid cycles: #{inspect(reason)} — entering recovery",
      component: :master,
      event: :domain_cycle_degraded,
      domain: id,
      consecutive: consecutive,
      reason_kind: Utils.reason_kind(reason)
    )

    {:next_state, :recovering,
     Recovery.put_runtime_fault(
       data,
       {:domain, id},
       {:cycle_degraded, %{reason: reason, consecutive: consecutive}}
     )}
  end

  def handle_event(:info, {:domain_cycle_degraded, id, reason, consecutive}, :recovering, data) do
    Logger.warning(
      "[Master] domain #{id} cycle still degraded: #{inspect(reason)}",
      component: :master,
      event: :domain_cycle_degraded,
      domain: id,
      consecutive: consecutive,
      reason_kind: Utils.reason_kind(reason)
    )

    {:keep_state,
     Recovery.put_runtime_fault(
       data,
       {:domain, id},
       {:cycle_degraded, %{reason: reason, consecutive: consecutive}}
     )}
  end

  def handle_event(:info, {:domain_cycle_degraded, _id, _reason, _consecutive}, _state, _data) do
    :keep_state_and_data
  end

  def handle_event(:info, {:domain_cycle_invalid, _id, _reason}, _state, _data) do
    :keep_state_and_data
  end

  def handle_event(:info, {:domain_cycle_recovered, id}, :recovering, data) do
    Logger.info(
      "[Master] domain #{id} cycle recovered",
      component: :master,
      event: :domain_cycle_recovered,
      domain: id
    )

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
  def handle_event(:info, {:slave_retreated, name, target_state}, state, data)
      when state in [:preop_ready, :deactivated] do
    Logger.warning(
      "[Master] slave #{name} retreated to #{target_state}",
      component: :master,
      event: :slave_retreated,
      slave: name,
      target_state: target_state
    )

    track_slave_fault(state, data, name, {:retreated, target_state})
  end

  def handle_event(:info, {:slave_retreated, name, target_state}, @operational, data) do
    Logger.warning(
      "[Master] slave #{name} retreated to #{target_state}",
      component: :master,
      event: :slave_retreated,
      slave: name,
      target_state: target_state
    )

    track_slave_fault(:operational, data, name, {:retreated, target_state})
  end

  def handle_event(:info, {:slave_retreated, name, target_state}, :recovering, data) do
    Logger.warning(
      "[Master] slave #{name} retreated to #{target_state}",
      component: :master,
      event: :slave_retreated,
      slave: name,
      target_state: target_state
    )

    track_slave_fault(:recovering, data, name, {:retreated, target_state})
  end

  def handle_event(:info, {:slave_retreated, name, target_state}, _state, _data) do
    Logger.warning(
      "[Master] slave #{name} retreated to #{target_state} (already not running)",
      component: :master,
      event: :slave_retreated,
      slave: name,
      target_state: target_state
    )

    :keep_state_and_data
  end

  # Slave physically disconnected (health poll wkc=0 or bus error)
  def handle_event(:info, {:slave_down, name, reason}, state, data)
      when state in [:preop_ready, :deactivated] do
    Logger.warning(
      "[Master] slave #{name} disconnected",
      component: :master,
      event: :slave_down,
      slave: name,
      reason_kind: Utils.reason_kind(reason)
    )

    track_slave_fault(state, data, name, {:down, reason})
  end

  def handle_event(:info, {:slave_down, name, reason}, @operational, data) do
    Logger.warning(
      "[Master] slave #{name} disconnected",
      component: :master,
      event: :slave_down,
      slave: name,
      reason_kind: Utils.reason_kind(reason)
    )

    track_slave_fault(:operational, data, name, {:down, reason})
  end

  def handle_event(:info, {:slave_down, name, reason}, :recovering, data) do
    Logger.warning(
      "[Master] slave #{name} disconnected",
      component: :master,
      event: :slave_down,
      slave: name,
      reason_kind: Utils.reason_kind(reason)
    )

    track_slave_fault(:recovering, data, name, {:down, reason})
  end

  def handle_event(:info, {:slave_down, name}, state, data)
      when state in [:preop_ready, :deactivated, :operational, :recovering] do
    handle_event(:info, {:slave_down, name, :disconnected}, state, data)
  end

  def handle_event(:info, {:slave_reconnected, _name}, state, _data)
      when state in [:operational, :recovering],
      do: :keep_state_and_data

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
    Logger.warning(
      "[Master] DC runtime failed: #{inspect(reason)} — entering recovery",
      component: :master,
      event: :dc_runtime_failed,
      reason_kind: Utils.reason_kind(reason)
    )

    {:next_state, :recovering,
     Recovery.put_runtime_fault(data, {:dc, :runtime}, {:failed, reason})}
  end

  def handle_event(:info, {:dc_runtime_failed, reason}, :recovering, data) do
    Logger.warning(
      "[Master] DC runtime still failing: #{inspect(reason)}",
      component: :master,
      event: :dc_runtime_failed,
      reason_kind: Utils.reason_kind(reason)
    )

    {:keep_state, Recovery.put_runtime_fault(data, {:dc, :runtime}, {:failed, reason})}
  end

  def handle_event(:info, {:dc_runtime_recovered}, :recovering, data) do
    Logger.info(
      "[Master] DC runtime recovered",
      component: :master,
      event: :dc_runtime_recovered
    )

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
        Telemetry.master_dc_lock_decision(
          :lost,
          :advisory,
          :continue,
          lock_state,
          max_sync_diff_ns
        )

        Logger.warning(
          "[Master] DC lock lost: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — advisory only",
          component: :master,
          event: :dc_lock_lost,
          policy: :advisory,
          outcome: :continue,
          lock_state: lock_state,
          max_sync_diff_ns: max_sync_diff_ns
        )

        :keep_state_and_data

      :recovering ->
        Telemetry.master_dc_lock_decision(
          :lost,
          :recovering,
          :enter_recovery,
          lock_state,
          max_sync_diff_ns
        )

        Logger.warning(
          "[Master] DC lock lost: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — entering recovery",
          component: :master,
          event: :dc_lock_lost,
          policy: :recovering,
          outcome: :enter_recovery,
          lock_state: lock_state,
          max_sync_diff_ns: max_sync_diff_ns
        )

        {:next_state, :recovering,
         Recovery.put_runtime_fault(data, {:dc, :lock}, {lock_state, max_sync_diff_ns})}

      :fatal ->
        Telemetry.master_dc_lock_decision(
          :lost,
          :fatal,
          :stop_session,
          lock_state,
          max_sync_diff_ns
        )

        Logger.error(
          "[Master] DC lock lost: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — stopping session",
          component: :master,
          event: :dc_lock_lost,
          policy: :fatal,
          outcome: :stop_session,
          lock_state: lock_state,
          max_sync_diff_ns: max_sync_diff_ns
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
        Telemetry.master_dc_lock_decision(
          :lost,
          :advisory,
          :continue,
          lock_state,
          max_sync_diff_ns
        )

        Logger.warning(
          "[Master] DC lock lost while recovering: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — advisory only",
          component: :master,
          event: :dc_lock_lost,
          policy: :advisory,
          outcome: :continue,
          lock_state: lock_state,
          max_sync_diff_ns: max_sync_diff_ns
        )

        :keep_state_and_data

      :recovering ->
        Telemetry.master_dc_lock_decision(
          :lost,
          :recovering,
          :keep_recovering,
          lock_state,
          max_sync_diff_ns
        )

        Logger.warning(
          "[Master] DC lock still lost: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)}",
          component: :master,
          event: :dc_lock_lost,
          policy: :recovering,
          outcome: :keep_recovering,
          lock_state: lock_state,
          max_sync_diff_ns: max_sync_diff_ns
        )

        {:keep_state,
         Recovery.put_runtime_fault(data, {:dc, :lock}, {lock_state, max_sync_diff_ns})}

      :fatal ->
        Telemetry.master_dc_lock_decision(
          :lost,
          :fatal,
          :stop_session,
          lock_state,
          max_sync_diff_ns
        )

        Logger.error(
          "[Master] DC lock lost while recovering: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — stopping session",
          component: :master,
          event: :dc_lock_lost,
          policy: :fatal,
          outcome: :stop_session,
          lock_state: lock_state,
          max_sync_diff_ns: max_sync_diff_ns
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
        Telemetry.master_dc_lock_decision(
          :regained,
          :advisory,
          :continue,
          :locked,
          max_sync_diff_ns
        )

        Logger.info(
          "[Master] DC lock regained (max_sync_diff_ns=#{inspect(max_sync_diff_ns)})",
          component: :master,
          event: :dc_lock_regained,
          policy: :advisory,
          outcome: :continue,
          lock_state: :locked,
          max_sync_diff_ns: max_sync_diff_ns
        )

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
        Telemetry.master_dc_lock_decision(
          :regained,
          :advisory,
          :continue,
          :locked,
          max_sync_diff_ns
        )

        Logger.info(
          "[Master] DC lock regained while recovering (max_sync_diff_ns=#{inspect(max_sync_diff_ns)})",
          component: :master,
          event: :dc_lock_regained,
          policy: :advisory,
          outcome: :continue,
          lock_state: :locked,
          max_sync_diff_ns: max_sync_diff_ns
        )

        :keep_state_and_data

      :recovering ->
        Telemetry.master_dc_lock_decision(
          :regained,
          :recovering,
          :resume_running,
          :locked,
          max_sync_diff_ns
        )

        Logger.info(
          "[Master] DC lock regained (max_sync_diff_ns=#{inspect(max_sync_diff_ns)})",
          component: :master,
          event: :dc_lock_regained,
          policy: :recovering,
          outcome: :resume_running,
          lock_state: :locked,
          max_sync_diff_ns: max_sync_diff_ns
        )

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

  defp reset_master(last_failure), do: %Master{last_failure: last_failure}

  defp runtime_target_from_configs(slave_configs) do
    if Config.activatable_slave_names(slave_configs || []) == [] do
      :preop
    else
      :op
    end
  end

  defp runtime_target_from_names([]), do: :preop
  defp runtime_target_from_names(_activatable_slaves), do: :op

  defp deactivated_target_settled?(state, _data, :safeop) when state == :deactivated, do: true
  defp deactivated_target_settled?(state, _data, :preop) when state == :preop_ready, do: true
  defp deactivated_target_settled?(_state, _data, _target), do: false

  defp reply_running_waiters(%{await_callers: []} = data), do: data

  defp reply_running_waiters(data) do
    reply = await_running_reply(Status.desired_public_state(data))
    reply_await_callers(data.await_callers, reply)
    %{data | await_callers: []}
  end

  defp await_running_reply(state) when state in [:preop_ready, :deactivated],
    do: quiesced_running_reply()

  defp await_running_reply(:operational), do: :ok

  defp quiesced_running_reply do
    case Bus.quiesce(Bus, @await_running_quiet_ms) do
      :ok -> :ok
      {:error, reason} -> {:error, {:bus_not_ready, reason}}
    end
  end

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

  defp critical_slave_fault?(data, _name, {:retreated, actual_state}) do
    desired_target = Status.desired_runtime_target(data)

    desired_target in [:preop, :safeop] and lower_than_target?(actual_state, desired_target)
  end

  defp critical_slave_fault?(data, name, {:down, _reason}) do
    desired_target = Status.desired_runtime_target(data)

    if desired_target in [:preop, :safeop] do
      true
    else
      slave_participates_in_domains?(data, name)
    end
  end

  defp critical_slave_fault?(_data, _name, _reason), do: false

  defp lower_than_target?(actual_state, desired_target)
       when is_atom(actual_state) and is_atom(desired_target) do
    slave_state_rank(actual_state) < slave_state_rank(desired_target)
  end

  defp lower_than_target?(_actual_state, _desired_target), do: false

  defp slave_state_rank(:init), do: 1
  defp slave_state_rank(:bootstrap), do: 1
  defp slave_state_rank(:preop), do: 2
  defp slave_state_rank(:safeop), do: 3
  defp slave_state_rank(:op), do: 4

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

  defp emit_state_change(old_state, new_state, data)
       when is_atom(old_state) and is_atom(new_state) do
    Telemetry.master_state_changed(
      old_state,
      new_state,
      Status.desired_public_state(data),
      Status.desired_runtime_target(data)
    )
  end

  # -- Session teardown ------------------------------------------------------

  defp stop_session(data) do
    Session.stop(data)
  end

  defp handle_activate_network(from, data) do
    case Activation.activate_network(data) do
      {:ok, next_state, active_data} ->
        maybe_reply_await_operational(active_data.await_operational_callers, next_state)

        {:next_state, next_state, %{active_data | await_operational_callers: []},
         [{:reply, from, :ok}]}

      {:activation_blocked, blocked_data} ->
        {:next_state, :activation_blocked, blocked_data, [{:reply, from, :ok}]}

      {:error, reason, failed_data} ->
        {:keep_state, failed_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp maybe_reply_await_operational(callers, :operational) do
    reply_await_callers(callers, :ok)
  end

  defp maybe_reply_await_operational(_callers, _next_state), do: :ok

  defp reply_await_callers(callers, reply) do
    Enum.each(callers, fn from -> :gen_statem.reply(from, reply) end)
  end
end
