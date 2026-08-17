defmodule EtherCAT.Slave.Runtime.Notifications do
  @moduledoc false

  alias EtherCAT.Domain.Status, as: DomainStatus
  alias EtherCAT.Notification
  alias EtherCAT.Slave
  alias EtherCAT.Slave.Status, as: SlaveStatus

  @spec subscribe(%Slave{}, pid()) :: %Slave{}
  def subscribe(data, pid) do
    subscriber_refs =
      if Map.has_key?(data.subscriber_refs, pid) do
        data.subscriber_refs
      else
        Map.put(data.subscriber_refs, pid, Process.monitor(pid))
      end

    %{
      data
      | protocol_subscriptions: MapSet.put(data.protocol_subscriptions, pid),
        subscriber_refs: subscriber_refs
    }
  end

  @spec state_changed(%Slave{}, SlaveStatus.state(), SlaveStatus.state()) :: :ok
  def state_changed(_data, state, state), do: :ok

  def state_changed(data, previous_state, current_state) do
    observed_at = System.monotonic_time(:microsecond)
    status = SlaveStatus.from_runtime(current_state, data)

    notification =
      Notification.slave_state_changed(data.name, previous_state, status, observed_at)

    dispatch(data, notification)
  end

  @spec domain_status(%Slave{}, DomainStatus.t()) :: %Slave{}
  def domain_status(data, %DomainStatus{} = status) do
    if attached_domain?(data, status.id) do
      retain_domain_status(data, status)
    else
      data
    end
  end

  @spec dispatch(%Slave{}, struct()) :: :ok
  def dispatch(data, message) do
    Enum.each(data.protocol_subscriptions, &send(&1, message))
    :ok
  end

  defp retain_domain_status(data, status) do
    previous = Map.get(data.domain_statuses, status.id)
    new_data = %{data | domain_statuses: Map.put(data.domain_statuses, status.id, status)}

    if same_domain_status?(previous, status) do
      new_data
    else
      dispatch(new_data, Notification.domain_status_changed(data.name, status))
      new_data
    end
  end

  defp attached_domain?(data, domain_id) do
    Map.has_key?(data.domain_statuses, domain_id) or
      Enum.any?(data.signal_registrations || %{}, fn {_signal_name, registration} ->
        registration.domain_id == domain_id
      end)
  end

  defp same_domain_status?(nil, _current), do: false

  defp same_domain_status?(previous, current) do
    {previous.lifecycle, previous.cycle_health, previous.reason} ==
      {current.lifecycle, current.cycle_health, current.reason}
  end
end
