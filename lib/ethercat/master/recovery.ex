defmodule EtherCAT.Master.Recovery do
  @moduledoc false

  require Logger

  alias EtherCAT.{Bus, Domain, Slave}
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Master.Activation
  alias EtherCAT.Master.Status
  alias EtherCAT.Slave.ESC.Registers
  alias EtherCAT.Telemetry
  alias EtherCAT.Utils

  @spec retry_activation_blocked_state(%EtherCAT.Master{}) ::
          {:ok, :deactivated | :operational | :preop_ready, %EtherCAT.Master{}}
          | {:activation_blocked, %EtherCAT.Master{}}
          | {:recovering, %EtherCAT.Master{}}
  def retry_activation_blocked_state(%{activation_failures: failures} = data)
      when map_size(failures) == 0 do
    maybe_resume_from_activation_blocked(data)
  end

  def retry_activation_blocked_state(%{activation_failures: failures} = data) do
    retried_failures =
      Enum.reduce(failures, %{}, fn
        {name, {:down, reason}}, acc ->
          Map.put(acc, name, {:down, reason})

        {name, {:reconnecting, _reason}}, acc ->
          Map.put(acc, name, {:reconnecting, :authorized})

        {name, {:reconnect_failed, _reason}}, acc ->
          retry_activation_reconnect_authorization(acc, name)

        {name, _last_failure}, acc ->
          case Slave.request(name, transition_request_target(data)) do
            :ok ->
              acc

            {:error, reason} ->
              Logger.warning(
                "[Master] activation-blocked retry: #{inspect(name)} still not in :#{transition_request_target(data)}: #{inspect(reason)}",
                component: :master,
                event: :activation_retry_failed,
                slave: name,
                target_state: transition_request_target(data),
                reason_kind: Utils.reason_kind(reason)
              )

              Map.put(acc, name, {transition_request_target(data), reason})
          end
      end)

    maybe_resume_from_activation_blocked(%{data | activation_failures: retried_failures})
  end

  @spec retry_recovering_state(%EtherCAT.Master{}) ::
          {:ok, :deactivated | :operational | :preop_ready, %EtherCAT.Master{}}
          | {:recovering, %EtherCAT.Master{}}
          | {:rediscover, term(), %EtherCAT.Master{}}
  def retry_recovering_state(data) do
    retried_data =
      data
      |> retry_slave_faults()
      |> retry_recovering_slaves()

    case maybe_request_topology_rediscovery(retried_data) do
      {:rediscover, reason, rediscovery_data} ->
        {:rediscover, reason, rediscovery_data}

      :continue ->
        retried_data
        |> maybe_restart_stopped_domains()
        |> maybe_restart_dc_runtime()
        |> maybe_resume_running()
    end
  end

  @spec authorize_activation_reconnect(%EtherCAT.Master{}, atom()) ::
          {:ok, %EtherCAT.Master{}} | {:error, %EtherCAT.Master{}} | :ignore
  def authorize_activation_reconnect(%{activation_failures: failures}, name)
      when not is_map_key(failures, name) do
    :ignore
  end

  def authorize_activation_reconnect(data, name) do
    Logger.info(
      "[Master] slave #{name} link restored during activation — authorizing reconnect",
      component: :master,
      event: :slave_reconnect_authorization_started,
      phase: :activation,
      slave: name
    )

    case Slave.authorize_reconnect(name) do
      :ok ->
        {:ok, put_activation_failure(data, name, {:reconnecting, :authorized})}

      {:error, reason} ->
        Logger.warning(
          "[Master] slave #{name} reconnect authorization failed during activation: #{inspect(reason)}",
          component: :master,
          event: :slave_reconnect_authorization_failed,
          phase: :activation,
          slave: name,
          reason_kind: Utils.reason_kind(reason)
        )

        {:error, put_activation_failure(data, name, {:reconnect_failed, reason})}
    end
  end

  @spec handle_activation_ready_preop(%EtherCAT.Master{}, atom()) ::
          {:ok, :deactivated | :operational | :preop_ready, %EtherCAT.Master{}}
          | {:activation_blocked, %EtherCAT.Master{}}
          | {:recovering, %EtherCAT.Master{}}
          | :ignore
  def handle_activation_ready_preop(%{activation_failures: failures}, name)
      when not is_map_key(failures, name) do
    :ignore
  end

  def handle_activation_ready_preop(data, name) do
    target = transition_request_target(data)

    if target == :preop do
      next_data =
        data
        |> Map.put(:activation_failures, Map.delete(data.activation_failures, name))
        |> clear_slave_fault(name)

      maybe_resume_from_activation_blocked(next_data)
    else
      Logger.info(
        "[Master] slave #{name} reached :preop during transition retry — requesting :#{target}",
        component: :master,
        event: :slave_transition_retry_started,
        phase: :activation,
        slave: name,
        target_state: target
      )

      case Slave.request(name, target) do
        :ok ->
          next_data =
            data
            |> Map.put(:activation_failures, Map.delete(data.activation_failures, name))
            |> clear_slave_fault(name)

          maybe_resume_from_activation_blocked(next_data)

        {:error, reason} ->
          Logger.warning(
            "[Master] slave #{name} still not in :#{target} during transition retry: #{inspect(reason)}",
            component: :master,
            event: :slave_transition_retry_failed,
            phase: :activation,
            slave: name,
            target_state: target,
            reason_kind: Utils.reason_kind(reason)
          )

          {:activation_blocked, put_activation_failure(data, name, {target, reason})}
      end
    end
  end

  @spec authorize_runtime_reconnect(%EtherCAT.Master{}, atom()) :: %EtherCAT.Master{}
  def authorize_runtime_reconnect(data, name) do
    Logger.info(
      "[Master] slave #{name} link restored — authorizing reconnect",
      component: :master,
      event: :slave_reconnect_authorization_started,
      phase: :runtime,
      slave: name
    )

    case Slave.authorize_reconnect(name) do
      :ok ->
        put_slave_fault(data, name, {:reconnecting, :authorized})

      {:error, reason} ->
        Logger.warning(
          "[Master] slave #{name} reconnect authorization failed: #{inspect(reason)}",
          component: :master,
          event: :slave_reconnect_authorization_failed,
          phase: :runtime,
          slave: name,
          reason_kind: Utils.reason_kind(reason)
        )

        put_slave_fault(data, name, {:reconnect_failed, reason})
    end
  end

  @spec handle_runtime_ready_preop(atom(), %EtherCAT.Master{}, atom()) ::
          {:ok, :deactivated | :operational | :preop_ready, %EtherCAT.Master{}}
          | {:keep, %EtherCAT.Master{}}
  def handle_runtime_ready_preop(state, data, name) when state in [:operational, :recovering] do
    target = transition_request_target(data)

    if target == :preop do
      recovered_data = clear_tracked_slave_fault(data, name)
      maybe_resume_recovered_state(state, recovered_data)
    else
      Logger.info(
        "[Master] slave #{name} reconnected and in :preop — requesting :#{target}",
        component: :master,
        event: :slave_transition_retry_started,
        phase: :runtime,
        slave: name,
        target_state: target
      )

      case Slave.request(name, target) do
        :ok ->
          recovered_data =
            data
            |> clear_tracked_slave_fault(name)
            |> maybe_restart_stopped_domains()
            |> maybe_restart_dc_runtime()

          maybe_resume_recovered_state(state, recovered_data)

        {:error, reason} ->
          Logger.warning(
            "[Master] slave #{name} :#{target} request failed after reconnect: #{inspect(reason)}",
            component: :master,
            event: :slave_transition_retry_failed,
            phase: :runtime,
            slave: name,
            target_state: target,
            reason_kind: Utils.reason_kind(reason)
          )

          next_data =
            if Map.has_key?(data.runtime_faults, {:slave, name}) do
              put_tracked_runtime_slave_fault(data, name, {:preop, reason})
            else
              put_slave_fault(data, name, {:preop, reason})
            end

          {:keep, next_data}
      end
    end
  end

  @spec lock_policy(%EtherCAT.Master{}) :: :advisory | :recovering | :fatal
  def lock_policy(%{dc_config: %{lock_policy: lock_policy}})
      when lock_policy in [:advisory, :recovering, :fatal] do
    lock_policy
  end

  def lock_policy(_data), do: :advisory

  @spec put_runtime_fault(%EtherCAT.Master{}, term(), term()) :: %EtherCAT.Master{}
  def put_runtime_fault(data, key, reason) do
    %{data | runtime_faults: Map.put(data.runtime_faults, key, reason)}
  end

  @spec clear_runtime_fault(%EtherCAT.Master{}, term()) :: %EtherCAT.Master{}
  def clear_runtime_fault(data, key) do
    %{data | runtime_faults: Map.delete(data.runtime_faults, key)}
  end

  @spec transition_runtime_fault(
          atom(),
          %EtherCAT.Master{}
        ) ::
          {:next_state, :recovering, %EtherCAT.Master{}}
          | {:keep_state, %EtherCAT.Master{}}
  def transition_runtime_fault(state, data)
      when state in [:preop_ready, :deactivated, :operational],
      do: {:next_state, :recovering, data}

  def transition_runtime_fault(:recovering, data), do: {:keep_state, data}
  def transition_runtime_fault(_state, data), do: {:keep_state, data}

  @spec maybe_restart_stopped_domains(%EtherCAT.Master{}) :: %EtherCAT.Master{}
  def maybe_restart_stopped_domains(%{runtime_faults: runtime_faults} = data) do
    if Status.desired_runtime_target(data) != :op do
      data
    else
      Enum.reduce(runtime_faults, data, fn
        {{:domain, domain_id}, {:stopped, reason}}, acc ->
          restart_stopped_domain(acc, domain_id, reason)

        _other_fault, acc ->
          acc
      end)
    end
  end

  @spec put_slave_fault(%EtherCAT.Master{}, atom(), term()) :: %EtherCAT.Master{}
  def put_slave_fault(data, name, reason) do
    previous = Map.get(data.slave_faults, name)

    if previous != reason do
      Telemetry.master_slave_fault_changed(name, previous, reason)
    end

    %{data | slave_faults: Map.put(data.slave_faults, name, reason)}
  end

  @spec clear_slave_fault(%EtherCAT.Master{}, atom()) :: %EtherCAT.Master{}
  def clear_slave_fault(data, name) do
    previous = Map.get(data.slave_faults, name)

    if not is_nil(previous) do
      Telemetry.master_slave_fault_changed(name, previous, nil)
    end

    %{data | slave_faults: Map.delete(data.slave_faults, name)}
  end

  @spec maybe_resume_running(%EtherCAT.Master{}) ::
          {:ok, :deactivated | :operational | :preop_ready, %EtherCAT.Master{}}
          | {:recovering, %EtherCAT.Master{}}
  def maybe_resume_running(data) do
    if map_size(data.activation_failures) == 0 and map_size(data.runtime_faults) == 0 do
      next_state = Status.desired_public_state(data)

      Logger.info(
        "[Master] recovery succeeded; desired runtime target #{inspect(Status.desired_runtime_target(data))} is healthy again",
        component: :master,
        event: :recovery_succeeded,
        runtime_target: Status.desired_runtime_target(data)
      )

      {:ok, next_state, %{data | activation_failures: %{}, runtime_faults: %{}}}
    else
      {:recovering, data}
    end
  end

  defp maybe_resume_recovered_state(:recovering, recovered_data) do
    case maybe_resume_running(recovered_data) do
      {:ok, next_state, healed_data} -> {:ok, next_state, healed_data}
      {:recovering, still_recovering} -> {:keep, still_recovering}
    end
  end

  defp maybe_resume_recovered_state(_state, recovered_data), do: {:keep, recovered_data}

  @spec maybe_resume_from_activation_blocked(%EtherCAT.Master{}) ::
          {:ok, :deactivated | :operational | :preop_ready, %EtherCAT.Master{}}
          | {:activation_blocked, %EtherCAT.Master{}}
          | {:recovering, %EtherCAT.Master{}}
  def maybe_resume_from_activation_blocked(data) do
    cond do
      map_size(data.activation_failures) > 0 ->
        {:activation_blocked, data}

      map_size(data.runtime_faults) > 0 ->
        {:recovering, data}

      true ->
        next_state = Status.desired_public_state(data)

        Logger.info(
          "[Master] transition retries succeeded; desired runtime target #{inspect(Status.desired_runtime_target(data))} is healthy again",
          component: :master,
          event: :activation_retry_succeeded,
          runtime_target: Status.desired_runtime_target(data)
        )

        {:ok, next_state, %{data | activation_failures: %{}, runtime_faults: %{}}}
    end
  end

  @spec unrecoverable_recovery_reason(%EtherCAT.Master{}) :: term() | nil
  def unrecoverable_recovery_reason(_data), do: nil

  @spec maybe_restart_dc_runtime(%EtherCAT.Master{}) :: %EtherCAT.Master{}
  def maybe_restart_dc_runtime(%{runtime_faults: runtime_faults} = data) do
    if Status.desired_runtime_target(data) == :op and
         Map.has_key?(runtime_faults, {:dc, :runtime}) and not dc_running?() and
         is_integer(data.dc_ref_station) do
      case Activation.start_dc_runtime(data, notify_recovered_on_success?: true) do
        {:ok, restarted_data} ->
          Logger.info(
            "[Master] restarted DC runtime",
            component: :master,
            event: :dc_runtime_restarted
          )

          restarted_data

        {:error, reason} ->
          Logger.debug(
            "[Master] failed to restart DC runtime: #{inspect(reason)}",
            component: :master,
            event: :dc_runtime_restart_failed,
            reason_kind: Utils.reason_kind(reason)
          )

          data
      end
    else
      data
    end
  end

  defp retry_recovering_slaves(%{runtime_faults: runtime_faults} = data) do
    target = transition_request_target(data)

    Enum.reduce(runtime_faults, data, fn
      {{:slave, name}, {:down, _reason}}, acc ->
        retry_recovering_slave_reconnect_authorization(acc, name)

      {{:slave, name}, {:reconnect_failed, _reason}}, acc ->
        retry_recovering_slave_reconnect_authorization(acc, name)

      {{:slave, name}, {:retreated, _target_state}}, acc ->
        retry_recovering_slave_request(acc, name, target)

      {{:slave, name}, {:preop, {:preop_configuration_failed, _reason}}}, acc ->
        retry_recovering_slave_preop_configuration(acc, name, target)

      {{:slave, name}, {:preop, reason}}, acc ->
        if retryable_runtime_slave_fault?(reason) do
          retry_recovering_slave_request(acc, name, target)
        else
          acc
        end

      _other, acc ->
        acc
    end)
  end

  @spec retry_slave_faults(%EtherCAT.Master{}) :: %EtherCAT.Master{}
  def retry_slave_faults(%{slave_faults: slave_faults} = data) do
    target = transition_request_target(data)

    next_faults =
      Enum.reduce(slave_faults, slave_faults, fn
        {name, reason}, acc ->
          if Map.has_key?(data.runtime_faults, {:slave, name}) do
            acc
          else
            case reason do
              {:down, _down_reason} ->
                retry_slave_reconnect_authorization(acc, name)

              {:retreated, _target_state} ->
                retry_slave_request(acc, name, target)

              {:preop, {:preop_configuration_failed, _reason}} ->
                retry_slave_preop_configuration(acc, name, target)

              {:preop, retry_reason} ->
                if retryable_runtime_slave_fault?(retry_reason) do
                  retry_slave_request(acc, name, target)
                else
                  acc
                end

              {:reconnect_failed, _reason} ->
                retry_slave_reconnect_authorization(acc, name)

              _other ->
                acc
            end
          end
      end)

    %{data | slave_faults: next_faults}
  end

  @spec retryable_slave_faults?(%EtherCAT.Master{}) :: boolean()
  def retryable_slave_faults?(%{slave_faults: slave_faults}) do
    Enum.any?(slave_faults, fn
      {_name, {:down, _reason}} -> true
      {_name, {:retreated, _target_state}} -> true
      {_name, {:preop, {:preop_configuration_failed, _reason}}} -> true
      {_name, {:preop, reason}} -> retryable_runtime_slave_fault?(reason)
      {_name, {:reconnect_failed, _reason}} -> true
      _other -> false
    end)
  end

  defp retry_recovering_slave_request(data, name, target) do
    case Slave.request(name, target) do
      :ok ->
        clear_tracked_slave_fault(data, name)

      {:error, reason} ->
        Logger.debug(
          "[Master] recovery retry: #{inspect(name)} still not in :#{target}: #{inspect(reason)}",
          component: :master,
          event: :slave_transition_retry_failed,
          phase: :recovery,
          slave: name,
          target_state: target,
          reason_kind: Utils.reason_kind(reason)
        )

        put_tracked_runtime_slave_fault(data, name, {:preop, reason})
    end
  end

  defp retry_slave_request(slave_faults, name, target) do
    case Slave.request(name, target) do
      :ok ->
        delete_slave_fault_entry(slave_faults, name)

      {:error, reason} ->
        Logger.debug(
          "[Master] slave retry: #{inspect(name)} still not in :#{target}: #{inspect(reason)}",
          component: :master,
          event: :slave_transition_retry_failed,
          phase: :steady_state,
          slave: name,
          target_state: target,
          reason_kind: Utils.reason_kind(reason)
        )

        put_slave_fault_entry(slave_faults, name, {:preop, reason})
    end
  end

  defp retry_recovering_slave_preop_configuration(data, name, target) do
    case Slave.retry_preop_configuration(name) do
      :ok ->
        maybe_finish_runtime_preop_retry(data, name, target)

      {:error, reason} ->
        Logger.debug(
          "[Master] recovery retry: #{inspect(name)} PREOP configuration still failing: #{inspect(reason)}",
          component: :master,
          event: :slave_preop_configuration_retry_failed,
          phase: :recovery,
          slave: name,
          reason_kind: Utils.reason_kind(reason)
        )

        put_tracked_runtime_slave_fault(
          data,
          name,
          {:preop, {:preop_configuration_failed, reason}}
        )
    end
  end

  defp retry_slave_preop_configuration(slave_faults, name, target) do
    case Slave.retry_preop_configuration(name) do
      :ok ->
        maybe_finish_slave_preop_retry(slave_faults, name, target)

      {:error, reason} ->
        Logger.debug(
          "[Master] slave retry: #{inspect(name)} PREOP configuration still failing: #{inspect(reason)}",
          component: :master,
          event: :slave_preop_configuration_retry_failed,
          phase: :steady_state,
          slave: name,
          reason_kind: Utils.reason_kind(reason)
        )

        put_slave_fault_entry(slave_faults, name, {:preop, {:preop_configuration_failed, reason}})
    end
  end

  defp retry_slave_reconnect_authorization(slave_faults, name) do
    case Slave.authorize_reconnect(name) do
      :ok ->
        put_slave_fault_entry(slave_faults, name, {:reconnecting, :authorized})

      {:error, :not_down} ->
        slave_faults

      {:error, reason} ->
        Logger.debug(
          "[Master] slave reconnect authorization retry failed for #{inspect(name)}: #{inspect(reason)}",
          component: :master,
          event: :slave_reconnect_authorization_retry_failed,
          phase: :steady_state,
          slave: name,
          reason_kind: Utils.reason_kind(reason)
        )

        put_slave_fault_entry(slave_faults, name, {:reconnect_failed, reason})
    end
  end

  defp retry_recovering_slave_reconnect_authorization(data, name) do
    case Slave.authorize_reconnect(name) do
      :ok ->
        put_tracked_runtime_slave_fault(data, name, {:reconnecting, :authorized})

      {:error, :not_down} ->
        data

      {:error, reason} ->
        Logger.debug(
          "[Master] recovery retry: slave reconnect authorization still failing for #{inspect(name)}: #{inspect(reason)}",
          component: :master,
          event: :slave_reconnect_authorization_retry_failed,
          phase: :recovery,
          slave: name,
          reason_kind: Utils.reason_kind(reason)
        )

        put_tracked_runtime_slave_fault(data, name, {:reconnect_failed, reason})
    end
  end

  defp maybe_request_topology_rediscovery(%{slave_count: expected_count} = data)
       when is_integer(expected_count) and expected_count > 0 do
    reconnect_failed =
      data.runtime_faults
      |> Enum.reduce([], fn
        {{:slave, name}, {:reconnect_failed, _reason}}, acc -> [name | acc]
        _other, acc -> acc
      end)
      |> Enum.sort()

    if reconnect_failed != [] and topology_visible_count() == {:ok, expected_count} do
      {:rediscover,
       {:topology_rediscovery_required,
        %{slaves: reconnect_failed, visible_slave_count: expected_count}}, data}
    else
      :continue
    end
  end

  defp maybe_request_topology_rediscovery(_data), do: :continue

  defp topology_visible_count do
    case Bus.transaction(Bus, Transaction.brd(Registers.esc_type())) do
      {:ok, [%{wkc: wkc}]} when is_integer(wkc) and wkc >= 0 -> {:ok, wkc}
      {:ok, replies} -> {:error, {:unexpected_replies, replies}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_activation_reconnect_authorization(activation_failures, name) do
    case Slave.authorize_reconnect(name) do
      :ok ->
        Map.put(activation_failures, name, {:reconnecting, :authorized})

      {:error, :not_down} ->
        activation_failures

      {:error, reason} ->
        Logger.debug(
          "[Master] activation-blocked reconnect authorization retry failed for #{inspect(name)}: #{inspect(reason)}",
          component: :master,
          event: :slave_reconnect_authorization_retry_failed,
          phase: :activation,
          slave: name,
          reason_kind: Utils.reason_kind(reason)
        )

        Map.put(activation_failures, name, {:reconnect_failed, reason})
    end
  end

  defp retryable_runtime_slave_fault?(
         {:preop_configuration_failed, {:domain_reregister_required, _, _}}
       ),
       do: false

  defp retryable_runtime_slave_fault?({:preop_configuration_failed, _reason}), do: false

  defp retryable_runtime_slave_fault?(_reason), do: true

  defp restart_stopped_domain(data, domain_id, reason) do
    case Domain.start_cycling(domain_id) do
      :ok ->
        Logger.info(
          "[Master] restarted domain #{domain_id} after stop caused by #{inspect(reason)}",
          component: :master,
          event: :domain_restarted,
          domain: domain_id,
          reason_kind: Utils.reason_kind(reason)
        )

        data

      {:error, :already_cycling} ->
        data

      {:error, restart_reason} ->
        Logger.debug(
          "[Master] failed to restart domain #{domain_id} after stop: #{inspect(restart_reason)}",
          component: :master,
          event: :domain_restart_failed,
          domain: domain_id,
          reason_kind: Utils.reason_kind(restart_reason)
        )

        data
    end
  end

  defp dc_running? do
    is_pid(Process.whereis(EtherCAT.DC))
  end

  defp clear_tracked_slave_fault(data, name) do
    data
    |> clear_slave_fault(name)
    |> clear_runtime_fault({:slave, name})
  end

  defp put_tracked_runtime_slave_fault(data, name, reason) do
    data
    |> put_slave_fault(name, reason)
    |> put_runtime_fault({:slave, name}, reason)
  end

  defp maybe_finish_runtime_preop_retry(data, name, :preop) do
    clear_tracked_slave_fault(data, name)
  end

  defp maybe_finish_runtime_preop_retry(data, name, target) do
    retry_recovering_slave_request(data, name, target)
  end

  defp maybe_finish_slave_preop_retry(slave_faults, name, :preop) do
    delete_slave_fault_entry(slave_faults, name)
  end

  defp maybe_finish_slave_preop_retry(slave_faults, name, target) do
    retry_slave_request(slave_faults, name, target)
  end

  defp put_slave_fault_entry(slave_faults, name, reason) do
    previous = Map.get(slave_faults, name)

    if previous != reason do
      Telemetry.master_slave_fault_changed(name, previous, reason)
    end

    Map.put(slave_faults, name, reason)
  end

  defp delete_slave_fault_entry(slave_faults, name) do
    previous = Map.get(slave_faults, name)

    if not is_nil(previous) do
      Telemetry.master_slave_fault_changed(name, previous, nil)
    end

    Map.delete(slave_faults, name)
  end

  defp transition_request_target(data), do: Status.desired_runtime_target(data)

  defp put_activation_failure(data, name, reason) do
    %{data | activation_failures: Map.put(data.activation_failures, name, reason)}
  end
end
