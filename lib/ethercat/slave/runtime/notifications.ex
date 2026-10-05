defmodule EtherCAT.Slave.Runtime.Notifications do
  @moduledoc false

  alias EtherCAT.Domain.Status, as: DomainStatus
  alias EtherCAT.Notification
  alias EtherCAT.Slave
  alias EtherCAT.Slave.Status, as: SlaveStatus

  @spec subscribe(%Slave{}, pid()) :: {reference(), %Slave{}}
  def subscribe(data, pid) do
    subscriber_refs =
      if Map.has_key?(data.subscriber_refs, pid) do
        data.subscriber_refs
      else
        Map.put(data.subscriber_refs, pid, Process.monitor(pid))
      end

    ref = make_ref()

    {ref,
     %{
       data
       | protocol_subscriptions: Map.put(data.protocol_subscriptions, ref, pid),
         subscriber_refs: subscriber_refs
     }}
  end

  @spec unsubscribe(%Slave{}, reference()) :: %Slave{}
  def unsubscribe(data, ref) do
    case Map.pop(data.protocol_subscriptions, ref) do
      {nil, _subscriptions} ->
        data

      {pid, subscriptions} ->
        data = %{data | protocol_subscriptions: subscriptions}

        subscribed? =
          Enum.any?(subscriptions, fn {_ref, subscriber} -> subscriber == pid end) or
            Enum.any?(data.subscriptions, fn {_name, subscribers} ->
              MapSet.member?(subscribers, pid)
            end)

        if subscribed? do
          data
        else
          Process.demonitor(Map.fetch!(data.subscriber_refs, pid), [:flush])
          %{data | subscriber_refs: Map.delete(data.subscriber_refs, pid)}
        end
    end
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
    Enum.each(data.protocol_subscriptions, fn {ref, pid} ->
      send(pid, {:ethercat, ref, message})
    end)

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
