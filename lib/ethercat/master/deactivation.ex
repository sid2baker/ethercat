defmodule EtherCAT.Master.Deactivation do
  @moduledoc false

  require Logger

  alias EtherCAT.{Domain, Slave}
  alias EtherCAT.Master.Config
  alias EtherCAT.Master.Session
  alias EtherCAT.Master.Status
  alias EtherCAT.Utils

  @spec deactivate_network(%EtherCAT.Master{}, :safeop | :preop) ::
          {:ok, :deactivated | :preop_ready, %EtherCAT.Master{}}
          | {:activation_blocked, %EtherCAT.Master{}}
  def deactivate_network(data, target) when target in [:safeop, :preop] do
    Logger.info(
      "[Master] deactivating — stopping cyclic runtime and retreating activatable slaves to :#{target}",
      component: :master,
      event: :deactivation_started,
      target_state: target
    )

    stopped_data =
      data
      |> stop_domain_cycles()
      |> Session.stop_dc_runtime()
      |> Map.put(:desired_runtime_target, target)
      |> Map.put(:runtime_faults, %{})
      |> Map.put(:activation_failures, %{})

    {activation_failures, slave_faults} =
      Enum.reduce(stopped_data.activatable_slaves, {%{}, stopped_data.slave_faults}, fn name,
                                                                                        {failures,
                                                                                         faults} ->
        case Slave.request(name, target) do
          :ok ->
            {failures, Map.delete(faults, name)}

          {:error, reason} ->
            Logger.warning(
              "[Master] slave #{inspect(name)} → #{target} failed during deactivation: #{inspect(reason)}",
              component: :master,
              event: :slave_deactivation_failed,
              slave: name,
              target_state: target,
              reason_kind: Utils.reason_kind(reason)
            )

            {Map.put(failures, name, {target, reason}), faults}
        end
      end)

    updated_data = %{
      stopped_data
      | activation_failures: activation_failures,
        slave_faults: slave_faults
    }

    if map_size(activation_failures) == 0 do
      {:ok, Status.desired_public_state(updated_data), updated_data}
    else
      {:activation_blocked, updated_data}
    end
  end

  defp stop_domain_cycles(data) do
    Enum.each(Config.domain_ids(data.domain_configs || []), fn domain_id ->
      case Domain.stop_cycling(domain_id) do
        :ok ->
          :ok

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Master] failed to stop domain #{domain_id} during deactivation: #{inspect(reason)}",
            component: :master,
            event: :domain_stop_failed,
            domain: domain_id,
            reason_kind: Utils.reason_kind(reason)
          )
      end
    end)

    data
  end
end
