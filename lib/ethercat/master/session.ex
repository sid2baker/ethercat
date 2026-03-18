defmodule EtherCAT.Master.Session do
  @moduledoc false

  alias EtherCAT.{Bus, DC}
  alias EtherCAT.Master.Config

  @spec stop_runtime(%EtherCAT.Master{}) :: :ok
  def stop_runtime(data) do
    Enum.each(data.domain_refs, fn {ref, _id} -> Process.demonitor(ref, [:flush]) end)
    Enum.each(data.slave_refs, fn {ref, _name} -> Process.demonitor(ref, [:flush]) end)
    demonitor_dc(data.dc_ref)

    stop_dc_runtime()

    Enum.each(data.slaves || [], fn {name, _station} ->
      terminate_slave(name)
    end)

    Enum.each(Config.domain_ids(data.domain_configs || []), fn domain_id ->
      terminate_domain(domain_id)
    end)
  end

  @spec stop(%EtherCAT.Master{}) :: :ok
  def stop(data) do
    stop_runtime(data)
    stop_bus()
  end

  defp stop_bus do
    case Process.whereis(Bus) do
      pid when is_pid(pid) -> DynamicSupervisor.terminate_child(EtherCAT.SessionSupervisor, pid)
      nil -> :ok
    end
  end

  defp stop_dc_runtime do
    case Process.whereis(DC) do
      pid when is_pid(pid) -> DynamicSupervisor.terminate_child(EtherCAT.SessionSupervisor, pid)
      nil -> :ok
    end
  end

  defp demonitor_dc(ref) when is_reference(ref), do: Process.demonitor(ref, [:flush])
  defp demonitor_dc(_ref), do: :ok

  defp terminate_slave(name) do
    case lookup_slave_pid(name) do
      pid when is_pid(pid) -> DynamicSupervisor.terminate_child(EtherCAT.SlaveSupervisor, pid)
      nil -> :ok
    end
  end

  defp terminate_domain(domain_id) do
    case lookup_domain_pid(domain_id) do
      pid when is_pid(pid) -> DynamicSupervisor.terminate_child(EtherCAT.SessionSupervisor, pid)
      nil -> :ok
    end
  end

  defp lookup_slave_pid(name) do
    case Registry.lookup(EtherCAT.Registry, {:slave, name}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp lookup_domain_pid(domain_id) do
    case Registry.lookup(EtherCAT.Registry, {:domain, domain_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
