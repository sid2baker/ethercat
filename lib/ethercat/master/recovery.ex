defmodule EtherCAT.Master.Recovery do
  @moduledoc false

  require Logger

  alias EtherCAT.Domain.API, as: DomainAPI
  alias EtherCAT.Master.Activation
  alias EtherCAT.Slave.API, as: SlaveAPI

  @spec retry_activation_blocked_state(%EtherCAT.Master{}) ::
          {:ok, :operational, %EtherCAT.Master{}}
          | {:activation_blocked, %EtherCAT.Master{}}
          | {:recovering, %EtherCAT.Master{}}
  def retry_activation_blocked_state(%{activation_failures: failures} = data)
      when map_size(failures) == 0 do
    maybe_resume_from_activation_blocked(data)
  end

  def retry_activation_blocked_state(%{activation_failures: failures} = data) do
    retried_failures =
      Enum.reduce(failures, %{}, fn
        {name, {:down, _}}, acc ->
          Map.put(acc, name, {:down, :disconnected})

        {name, {:reconnecting, _reason}}, acc ->
          Map.put(acc, name, {:reconnecting, :authorized})

        {name, {:reconnect_failed, _reason}}, acc ->
          retry_activation_reconnect_authorization(acc, name)

        {name, _last_failure}, acc ->
          case SlaveAPI.request(name, :op) do
            :ok ->
              acc

            {:error, reason} ->
              Logger.warning(
                "[Master] activation-blocked retry: #{inspect(name)} still not in :op: #{inspect(reason)}"
              )

              Map.put(acc, name, {:op, reason})
          end
      end)

    maybe_resume_from_activation_blocked(%{data | activation_failures: retried_failures})
  end

  @spec retry_recovering_state(%EtherCAT.Master{}) ::
          {:ok, :operational, %EtherCAT.Master{}}
          | {:recovering, %EtherCAT.Master{}}
  def retry_recovering_state(data) do
    data
    |> retry_slave_faults()
    |> retry_recovering_slaves()
    |> maybe_restart_stopped_domains()
    |> maybe_restart_dc_runtime()
    |> maybe_resume_running()
  end

  @spec authorize_activation_reconnect(%EtherCAT.Master{}, atom()) ::
          {:ok, %EtherCAT.Master{}} | {:error, %EtherCAT.Master{}} | :ignore
  def authorize_activation_reconnect(%{activation_failures: failures}, name)
      when not is_map_key(failures, name) do
    :ignore
  end

  def authorize_activation_reconnect(data, name) do
    Logger.info("[Master] slave #{name} link restored during activation — authorizing reconnect")

    case SlaveAPI.authorize_reconnect(name) do
      :ok ->
        {:ok, put_activation_failure(data, name, {:reconnecting, :authorized})}

      {:error, reason} ->
        Logger.warning(
          "[Master] slave #{name} reconnect authorization failed during activation: #{inspect(reason)}"
        )

        {:error, put_activation_failure(data, name, {:reconnect_failed, reason})}
    end
  end

  @spec handle_activation_ready_preop(%EtherCAT.Master{}, atom()) ::
          {:ok, :operational, %EtherCAT.Master{}}
          | {:activation_blocked, %EtherCAT.Master{}}
          | {:recovering, %EtherCAT.Master{}}
          | :ignore
  def handle_activation_ready_preop(%{activation_failures: failures}, name)
      when not is_map_key(failures, name) do
    :ignore
  end

  def handle_activation_ready_preop(data, name) do
    Logger.info("[Master] slave #{name} reached :preop during activation retry — requesting :op")

    case SlaveAPI.request(name, :op) do
      :ok ->
        next_data = %{data | activation_failures: Map.delete(data.activation_failures, name)}
        maybe_resume_from_activation_blocked(next_data)

      {:error, reason} ->
        Logger.warning(
          "[Master] slave #{name} still not in :op during activation retry: #{inspect(reason)}"
        )

        {:activation_blocked, put_activation_failure(data, name, {:op, reason})}
    end
  end

  @spec authorize_runtime_reconnect(%EtherCAT.Master{}, atom()) :: %EtherCAT.Master{}
  def authorize_runtime_reconnect(data, name) do
    Logger.info("[Master] slave #{name} link restored — authorizing reconnect")

    case SlaveAPI.authorize_reconnect(name) do
      :ok ->
        put_slave_fault(data, name, {:reconnecting, :authorized})

      {:error, reason} ->
        Logger.warning(
          "[Master] slave #{name} reconnect authorization failed: #{inspect(reason)}"
        )

        put_slave_fault(data, name, {:reconnect_failed, reason})
    end
  end

  @spec handle_runtime_ready_preop(atom(), %EtherCAT.Master{}, atom()) ::
          {:ok, :operational, %EtherCAT.Master{}}
          | {:keep, %EtherCAT.Master{}}
          | {:ok, :recovering, %EtherCAT.Master{}}
  def handle_runtime_ready_preop(state, data, name) when state in [:operational, :recovering] do
    Logger.info("[Master] slave #{name} reconnected and in :preop — requesting :op")

    case SlaveAPI.request(name, :op) do
      :ok ->
        recovered_data =
          data
          |> clear_tracked_slave_fault(name)
          |> maybe_restart_stopped_domains()
          |> maybe_restart_dc_runtime()

        if state == :recovering do
          case maybe_resume_running(recovered_data) do
            {:ok, next_state, healed_data} -> {:ok, next_state, healed_data}
            {:recovering, still_recovering} -> {:keep, still_recovering}
          end
        else
          {:keep, recovered_data}
        end

      {:error, reason} ->
        Logger.warning(
          "[Master] slave #{name} :op request failed after reconnect: #{inspect(reason)}"
        )

        {:keep, put_slave_fault(data, name, {:preop, reason})}
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
  def transition_runtime_fault(state, data) when state in [:preop_ready, :operational],
    do: {:next_state, :recovering, data}

  def transition_runtime_fault(:recovering, data), do: {:keep_state, data}
  def transition_runtime_fault(_state, data), do: {:keep_state, data}

  @spec maybe_restart_stopped_domains(%EtherCAT.Master{}) :: %EtherCAT.Master{}
  def maybe_restart_stopped_domains(%{runtime_faults: runtime_faults} = data) do
    Enum.reduce(runtime_faults, data, fn
      {{:domain, domain_id}, {:stopped, reason}}, acc ->
        restart_stopped_domain(acc, domain_id, reason)

      _other_fault, acc ->
        acc
    end)
  end

  @spec put_slave_fault(%EtherCAT.Master{}, atom(), term()) :: %EtherCAT.Master{}
  def put_slave_fault(data, name, reason) do
    %{data | slave_faults: Map.put(data.slave_faults, name, reason)}
  end

  @spec clear_slave_fault(%EtherCAT.Master{}, atom()) :: %EtherCAT.Master{}
  def clear_slave_fault(data, name) do
    %{data | slave_faults: Map.delete(data.slave_faults, name)}
  end

  @spec maybe_resume_running(%EtherCAT.Master{}) ::
          {:ok, :operational, %EtherCAT.Master{}}
          | {:recovering, %EtherCAT.Master{}}
  def maybe_resume_running(data) do
    if map_size(data.activation_failures) == 0 and map_size(data.runtime_faults) == 0 do
      Logger.info("[Master] recovery succeeded; operational path is healthy again")
      {:ok, :operational, %{data | activation_failures: %{}, runtime_faults: %{}}}
    else
      {:recovering, data}
    end
  end

  @spec maybe_resume_from_activation_blocked(%EtherCAT.Master{}) ::
          {:ok, :operational, %EtherCAT.Master{}}
          | {:activation_blocked, %EtherCAT.Master{}}
          | {:recovering, %EtherCAT.Master{}}
  def maybe_resume_from_activation_blocked(data) do
    cond do
      map_size(data.activation_failures) > 0 ->
        {:activation_blocked, data}

      map_size(data.runtime_faults) > 0 ->
        {:recovering, data}

      true ->
        Logger.info("[Master] activation retries succeeded; operational path is healthy again")
        {:ok, :operational, %{data | activation_failures: %{}, runtime_faults: %{}}}
    end
  end

  @spec unrecoverable_recovery_reason(%EtherCAT.Master{}) :: term() | nil
  def unrecoverable_recovery_reason(_data), do: nil

  @spec maybe_restart_dc_runtime(%EtherCAT.Master{}) :: %EtherCAT.Master{}
  def maybe_restart_dc_runtime(%{runtime_faults: runtime_faults} = data) do
    if Map.has_key?(runtime_faults, {:dc, :runtime}) and not dc_running?() and
         is_integer(data.dc_ref_station) do
      case Activation.start_dc_runtime(data) do
        {:ok, restarted_data} ->
          Logger.info("[Master] restarted DC runtime")
          clear_runtime_fault(restarted_data, {:dc, :runtime})

        {:error, reason} ->
          Logger.warning("[Master] failed to restart DC runtime: #{inspect(reason)}")
          data
      end
    else
      data
    end
  end

  defp retry_recovering_slaves(%{runtime_faults: runtime_faults} = data) do
    next_faults =
      Enum.reduce(runtime_faults, runtime_faults, fn
        {{:slave, name}, {:retreated, _target_state}}, acc ->
          retry_runtime_slave_request(acc, name)

        {{:slave, name}, {:preop, reason}}, acc ->
          if retryable_runtime_slave_fault?(reason) do
            retry_runtime_slave_request(acc, name)
          else
            acc
          end

        _other, acc ->
          acc
      end)

    %{data | runtime_faults: next_faults}
  end

  @spec retry_slave_faults(%EtherCAT.Master{}) :: %EtherCAT.Master{}
  def retry_slave_faults(%{slave_faults: slave_faults} = data) do
    next_faults =
      Enum.reduce(slave_faults, slave_faults, fn
        {name, {:retreated, _target_state}}, acc ->
          retry_slave_op_request(acc, name)

        {name, {:preop, reason}}, acc ->
          if retryable_runtime_slave_fault?(reason) do
            retry_slave_op_request(acc, name)
          else
            acc
          end

        {name, {:reconnect_failed, _reason}}, acc ->
          retry_slave_reconnect_authorization(acc, name)

        _other, acc ->
          acc
      end)

    %{data | slave_faults: next_faults}
  end

  @spec retryable_slave_faults?(%EtherCAT.Master{}) :: boolean()
  def retryable_slave_faults?(%{slave_faults: slave_faults}) do
    Enum.any?(slave_faults, fn
      {_name, {:retreated, _target_state}} -> true
      {_name, {:preop, reason}} -> retryable_runtime_slave_fault?(reason)
      {_name, {:reconnect_failed, _reason}} -> true
      _other -> false
    end)
  end

  defp retry_runtime_slave_request(runtime_faults, name) do
    case SlaveAPI.request(name, :op) do
      :ok ->
        Map.delete(runtime_faults, {:slave, name})

      {:error, reason} ->
        Logger.warning(
          "[Master] recovery retry: #{inspect(name)} still not in :op: #{inspect(reason)}"
        )

        Map.put(runtime_faults, {:slave, name}, {:preop, reason})
    end
  end

  defp retry_slave_op_request(slave_faults, name) do
    case SlaveAPI.request(name, :op) do
      :ok ->
        Map.delete(slave_faults, name)

      {:error, reason} ->
        Logger.warning(
          "[Master] slave retry: #{inspect(name)} still not in :op: #{inspect(reason)}"
        )

        Map.put(slave_faults, name, {:preop, reason})
    end
  end

  defp retry_slave_reconnect_authorization(slave_faults, name) do
    case SlaveAPI.authorize_reconnect(name) do
      :ok ->
        Map.put(slave_faults, name, {:reconnecting, :authorized})

      {:error, reason} ->
        Logger.warning(
          "[Master] slave reconnect authorization retry failed for #{inspect(name)}: #{inspect(reason)}"
        )

        Map.put(slave_faults, name, {:reconnect_failed, reason})
    end
  end

  defp retry_activation_reconnect_authorization(activation_failures, name) do
    case SlaveAPI.authorize_reconnect(name) do
      :ok ->
        Map.put(activation_failures, name, {:reconnecting, :authorized})

      {:error, reason} ->
        Logger.warning(
          "[Master] activation-blocked reconnect authorization retry failed for #{inspect(name)}: #{inspect(reason)}"
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
    case DomainAPI.start_cycling(domain_id) do
      :ok ->
        Logger.info(
          "[Master] restarted domain #{domain_id} after stop caused by #{inspect(reason)}"
        )

        data

      {:error, :already_cycling} ->
        data

      {:error, restart_reason} ->
        Logger.warning(
          "[Master] failed to restart domain #{domain_id} after stop: #{inspect(restart_reason)}"
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

  defp put_activation_failure(data, name, reason) do
    %{data | activation_failures: Map.put(data.activation_failures, name, reason)}
  end
end
