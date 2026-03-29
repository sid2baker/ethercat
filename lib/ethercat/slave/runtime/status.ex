defmodule EtherCAT.Slave.Runtime.Status do
  @moduledoc false

  alias EtherCAT.Domain
  alias EtherCAT.Slave
  alias EtherCAT.Slave.Runtime.DeviceState
  alias EtherCAT.Slave.Runtime.Signals

  @spec info_snapshot(atom(), %Slave{}) :: map()
  def info_snapshot(state, data) do
    attachments = Signals.attachment_summaries(data.signal_registrations)
    description = DeviceState.snapshot(state, data)

    %{
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
      pdo_health: pdo_health_snapshot(data.signal_registrations),
      signals: signal_summaries(data.signal_registrations),
      configuration_error: data.configuration_error,
      device_type: description.device_type,
      endpoints: description.endpoints,
      commands: description.commands,
      capabilities: description.commands,
      device_cycle: data.device_cycle,
      device_state: description.state,
      device_faults: data.device_faults,
      driver_error: data.driver_error
    }
  end

  defp signal_summaries(nil), do: []

  defp signal_summaries(registrations) do
    registrations
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

  defp pdo_health_snapshot(nil), do: %{state: :unattached, domains: []}

  defp pdo_health_snapshot(registrations) when is_map(registrations) do
    domains =
      registrations
      |> Map.values()
      |> Enum.map(& &1.domain_id)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&domain_health_snapshot/1)

    %{state: aggregate_pdo_health(domains), domains: domains}
  end

  defp domain_health_snapshot(domain_id) do
    case Domain.info(domain_id) do
      {:ok, %{freshness: freshness}} ->
        Map.put(freshness, :id, domain_id)

      {:error, _reason} ->
        %{
          id: domain_id,
          state: :not_ready,
          refreshed_at_us: nil,
          age_us: nil,
          stale_after_us: nil
        }
    end
  end

  defp aggregate_pdo_health([]), do: :unattached

  defp aggregate_pdo_health(domains) do
    cond do
      Enum.any?(domains, &(&1.state == :stale)) -> :stale
      Enum.any?(domains, &(&1.state == :not_ready)) -> :not_ready
      true -> :fresh
    end
  end
end
