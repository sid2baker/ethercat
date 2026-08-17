defmodule EtherCAT.Domain.Notifications do
  @moduledoc false

  alias EtherCAT.Domain
  alias EtherCAT.Domain.Layout
  alias EtherCAT.Domain.Status

  @spec dispatch(%Domain{}, Status.lifecycle(), Status.cycle_health(), term() | nil, integer()) ::
          :ok
  def dispatch(data, lifecycle, cycle_health, reason, observed_at) do
    status = Status.protocol_status(data.id, lifecycle, cycle_health, reason, observed_at)

    data.layout
    |> Layout.slave_names()
    |> Enum.each(&dispatch_to_slave(&1, status))
  end

  @spec dispatch_to_slaves(
          [{atom(), non_neg_integer()} | %{required(:name) => atom()}],
          atom(),
          Status.lifecycle(),
          Status.cycle_health(),
          term()
        ) :: :ok
  def dispatch_to_slaves(slaves, domain_id, lifecycle, cycle_health, reason) do
    status =
      Status.protocol_status(
        domain_id,
        lifecycle,
        cycle_health,
        reason,
        System.monotonic_time(:microsecond)
      )

    Enum.each(slaves, fn
      {slave_name, _station} -> dispatch_to_slave(slave_name, status)
      %{name: slave_name} -> dispatch_to_slave(slave_name, status)
    end)
  end

  defp dispatch_to_slave(slave_name, status) do
    case Registry.lookup(EtherCAT.Registry, {:slave, slave_name}) do
      [{pid, _value}] -> send(pid, {:domain_status, status})
      [] -> :ok
    end
  end
end
