defmodule EtherCAT.Master.Activation do
  @moduledoc false

  require Logger

  alias EtherCAT.{Bus, DC, Domain, Slave, Telemetry, Utils}
  alias EtherCAT.Master.Config
  alias EtherCAT.Master.Session
  alias EtherCAT.Master.Status

  @activation_quiet_ms 2

  @spec activate_network(%EtherCAT.Master{}) ::
          {:ok, :preop_ready | :operational, %EtherCAT.Master{}}
          | {:activation_blocked, %EtherCAT.Master{}}
          | {:error, term(), %EtherCAT.Master{}}
  def activate_network(%{activatable_slaves: []} = data) do
    started_at_ms = System.monotonic_time(:millisecond)

    Logger.info(
      "[Master] dynamic startup: slaves held in :preop for runtime configuration",
      component: :master,
      event: :activation_started,
      runtime_target: :preop
    )

    result =
      case quiesce_bus() do
        :ok ->
          {:ok, :preop_ready, %{data | activation_failures: %{}}}

        {:error, reason} ->
          {:error, {:bus_not_ready, reason}, data}
      end

    emit_activation_result(result, data, started_at_ms)
    result
  end

  def activate_network(data) do
    started_at_ms = System.monotonic_time(:millisecond)

    Logger.info(
      "[Master] activating — starting DC, cyclic domains, and advancing slaves to :op",
      component: :master,
      event: :activation_started,
      runtime_target: :op
    )

    result =
      case quiesce_bus() do
        :ok ->
          do_activate_network(data)

        {:error, reason} ->
          {:error, {:bus_not_ready, reason}, data}
      end

    emit_activation_result(result, data, started_at_ms)
    result
  end

  defp do_activate_network(data) do
    case preop_activation_failures(data.activatable_slaves) do
      activation_failures when map_size(activation_failures) > 0 ->
        Logger.warning(
          "[Master] activation incomplete; blocked for #{inspect(Map.keys(activation_failures))}",
          component: :master,
          event: :activation_blocked,
          runtime_target: Status.desired_runtime_target(data),
          blocked_count: map_size(activation_failures)
        )

        {:activation_blocked, %{data | activation_failures: activation_failures}}

      _none ->
        case start_dc_runtime(data) do
          {:ok, dc_data} ->
            with :ok <- start_domain_cycles(dc_data),
                 :ok <- await_dc_lock_if_requested(dc_data) do
              activation_failures = activate_required_slaves(dc_data.activatable_slaves)

              activated_data = %{dc_data | activation_failures: activation_failures}

              if map_size(activation_failures) == 0 do
                {:ok, :operational, activated_data}
              else
                Logger.warning(
                  "[Master] activation incomplete; blocked for #{inspect(Map.keys(activation_failures))}",
                  component: :master,
                  event: :activation_blocked,
                  runtime_target: Status.desired_runtime_target(data),
                  blocked_count: map_size(activation_failures)
                )

                {:activation_blocked, activated_data}
              end
            else
              {:error, reason} ->
                {:error, reason, rollback_started_runtime(dc_data)}
            end

          {:error, reason} ->
            {:error, reason, data}
        end
    end
  end

  @spec start_dc_runtime(%EtherCAT.Master{}, keyword()) ::
          {:ok, %EtherCAT.Master{}} | {:error, term()}
  def start_dc_runtime(data, opts \\ [])

  def start_dc_runtime(%{dc_ref_station: nil} = data, _opts), do: {:ok, %{data | dc_ref: nil}}

  def start_dc_runtime(data, opts) do
    case DynamicSupervisor.start_child(
           EtherCAT.SessionSupervisor,
           {DC,
            bus: Bus,
            ref_station: data.dc_ref_station,
            monitored_stations: data.dc_stations,
            config: data.dc_config,
            notify_recovered_on_success?: Keyword.get(opts, :notify_recovered_on_success?, false)}
         ) do
      {:ok, pid} ->
        {:ok, %{data | dc_ref: Process.monitor(pid)}}

      {:error, {:already_started, pid}} ->
        {:ok, %{data | dc_ref: Process.monitor(pid)}}

      {:error, reason} ->
        {:error, {:dc_start_failed, reason}}
    end
  end

  defp start_domain_cycles(data) do
    Enum.reduce_while(Config.domain_ids(data.domain_configs || []), :ok, fn id, :ok ->
      case Domain.start_cycling(id) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:domain_cycle_start_failed, id, reason}}}
      end
    end)
  end

  defp await_dc_lock_if_requested(%{dc_config: nil}), do: :ok

  defp await_dc_lock_if_requested(%{dc_config: %{await_lock?: false}}), do: :ok

  defp await_dc_lock_if_requested(data) do
    timeout_ms = data.dc_config.lock_timeout_ms

    if dc_running?() do
      case DC.await_locked(DC, timeout_ms) do
        :ok ->
          :ok

        {:error, :timeout} ->
          {:error, {:dc_lock_timeout, Status.dc_status(data)}}

        {:error, reason} ->
          {:error, {:dc_lock_failed, reason}}
      end
    else
      {:error, {:dc_lock_unavailable, :no_active_dc_runtime}}
    end
  end

  defp activate_required_slaves(slave_names) do
    {safeop_ready, safeop_failures} =
      Enum.reduce(slave_names, {[], %{}}, fn name, {ready, failures} ->
        case Slave.request(name, :safeop) do
          :ok ->
            {[name | ready], failures}

          {:error, reason} ->
            Logger.warning(
              "[Master] slave #{inspect(name)} → safeop failed: #{inspect(reason)}",
              component: :master,
              event: :slave_safeop_failed,
              slave: name,
              reason_kind: Utils.reason_kind(reason)
            )

            {ready, Map.put(failures, name, {:safeop, reason})}
        end
      end)

    Enum.reduce(safeop_ready, safeop_failures, fn name, failures ->
      case Slave.request(name, :op) do
        :ok ->
          failures

        {:error, reason} ->
          Logger.warning(
            "[Master] slave #{inspect(name)} → op failed: #{inspect(reason)}",
            component: :master,
            event: :slave_op_failed,
            slave: name,
            reason_kind: Utils.reason_kind(reason)
          )

          Map.put(failures, name, {:op, reason})
      end
    end)
  end

  defp preop_activation_failures(slave_names) do
    Enum.reduce(slave_names, %{}, fn name, failures ->
      case Slave.info(name) do
        {:ok, %{al_state: :preop, configuration_error: reason}} when not is_nil(reason) ->
          Logger.warning(
            "[Master] slave #{inspect(name)} blocked in PREOP: #{inspect(reason)}",
            component: :master,
            event: :slave_preop_blocked,
            slave: name,
            reason_kind: Utils.reason_kind(reason)
          )

          Map.put(failures, name, {:safeop, {:preop_configuration_failed, reason}})

        _other ->
          failures
      end
    end)
  end

  defp dc_running? do
    is_pid(Process.whereis(DC))
  end

  defp rollback_started_runtime(data) do
    data
    |> stop_started_domain_cycles()
    |> stop_started_dc_runtime()
  end

  defp stop_started_domain_cycles(data) do
    Enum.each(Config.domain_ids(data.domain_configs || []), fn domain_id ->
      case Domain.stop_cycling(domain_id) do
        :ok ->
          :ok

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Master] failed to stop domain #{domain_id} during activation rollback: #{inspect(reason)}",
            component: :master,
            event: :activation_rollback_domain_stop_failed,
            domain: domain_id,
            reason_kind: Utils.reason_kind(reason)
          )
      end
    end)

    data
  end

  defp stop_started_dc_runtime(%{dc_ref: ref} = data) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    stop_started_dc_runtime(%{data | dc_ref: nil})
  end

  defp stop_started_dc_runtime(data), do: Session.stop_dc_runtime(data)

  defp quiesce_bus do
    Bus.quiesce(Bus, @activation_quiet_ms)
  end

  defp emit_activation_result(result, data, started_at_ms) do
    duration_ms = System.monotonic_time(:millisecond) - started_at_ms
    runtime_target = Status.desired_runtime_target(data)

    case result do
      {:ok, _next_state, _active_data} ->
        Telemetry.master_activation_result(:ok, duration_ms, runtime_target, 0, nil)

      {:activation_blocked, blocked_data} ->
        Telemetry.master_activation_result(
          :blocked,
          duration_ms,
          runtime_target,
          map_size(blocked_data.activation_failures),
          nil
        )

      {:error, reason, _failed_data} ->
        Telemetry.master_activation_result(:error, duration_ms, runtime_target, 0, reason)
    end
  end
end
