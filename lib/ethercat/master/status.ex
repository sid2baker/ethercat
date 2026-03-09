defmodule EtherCAT.Master.Status do
  @moduledoc false

  alias EtherCAT.{Bus, DC, Domain}
  alias EtherCAT.DC.Status, as: DCStatus

  @spec activation_blocked_reply(%EtherCAT.Master{}) :: {:error, term()}
  def activation_blocked_reply(data) do
    activation_failures = data.activation_failures
    runtime_faults = data.runtime_faults

    cond do
      map_size(activation_failures) > 0 and map_size(runtime_faults) == 0 ->
        {:error, {:activation_failed, activation_failures}}

      map_size(activation_failures) == 0 and map_size(runtime_faults) > 0 ->
        {:error, {:runtime_degraded, runtime_faults}}

      true ->
        {:error,
         {:activation_blocked,
          %{activation_failures: activation_failures, runtime_faults: runtime_faults}}}
    end
  end

  @spec recovering_reply(%EtherCAT.Master{}) :: {:error, {:runtime_degraded, map()}}
  def recovering_reply(%{runtime_faults: runtime_faults}) do
    {:error, {:runtime_degraded, runtime_faults}}
  end

  @spec activation_blocked_summary(%EtherCAT.Master{}) :: String.t()
  def activation_blocked_summary(data) do
    activation_count = map_size(data.activation_failures)
    runtime_count = map_size(data.runtime_faults)
    "activation_failures=#{activation_count} runtime_faults=#{runtime_count}"
  end

  @spec recovering_summary(%EtherCAT.Master{}) :: String.t()
  def recovering_summary(data) do
    "runtime_faults=#{map_size(data.runtime_faults)} activation_failures=#{map_size(data.activation_failures)}"
  end

  @spec dc_status(%EtherCAT.Master{}) :: DCStatus.t()
  def dc_status(%{dc_config: nil}) do
    %DCStatus{lock_state: :disabled}
  end

  def dc_status(data) do
    base_status = %DCStatus{
      configured?: true,
      active?: false,
      cycle_ns: dc_cycle_ns(data),
      await_lock?: data.dc_config.await_lock?,
      lock_policy: data.dc_config.lock_policy,
      reference_station: data.dc_ref_station,
      reference_clock: reference_clock_name(data),
      lock_state: :inactive
    }

    if dc_running?() do
      case DC.status(DC) do
        %DCStatus{} = status ->
          %{status | reference_clock: reference_clock_name(data)}

        {:error, _reason} ->
          base_status
      end
    else
      base_status
    end
  end

  @spec reference_clock_reply(DCStatus.t()) ::
          {:ok, %{name: atom() | nil, station: non_neg_integer()}}
          | {:error, :dc_disabled | :no_reference_clock}
  def reference_clock_reply(%DCStatus{reference_station: station, reference_clock: name})
      when is_integer(station) do
    {:ok, %{name: name, station: station}}
  end

  def reference_clock_reply(%DCStatus{configured?: false}), do: {:error, :dc_disabled}
  def reference_clock_reply(_status), do: {:error, :no_reference_clock}

  @spec slaves(%EtherCAT.Master{}) ::
          [
            %{
              name: atom(),
              station: non_neg_integer(),
              server: :gen_statem.server_ref(),
              pid: pid() | nil
            }
          ]
  def slaves(data) do
    Enum.map(data.slaves, fn {name, station} ->
      %{name: name, station: station, server: slave_server(name), pid: lookup_slave_pid(name)}
    end)
  end

  @spec domains(%EtherCAT.Master{}) :: [{atom(), pos_integer(), pid()}]
  def domains(data) do
    (data.domain_configs || [])
    |> Enum.flat_map(fn config ->
      case Registry.lookup(EtherCAT.Registry, {:domain, config.id}) do
        [{pid, _}] ->
          case Domain.info(config.id) do
            {:ok, %{cycle_time_us: cycle_time_us}} -> [{config.id, cycle_time_us, pid}]
            _ -> []
          end

        [] ->
          []
      end
    end)
  end

  @spec bus_public_ref(%EtherCAT.Master{}) :: Bus.server() | nil
  def bus_public_ref(_data) do
    if bus_running?(), do: Bus, else: nil
  end

  defp reference_clock_name(%{dc_ref_station: nil}), do: nil

  defp reference_clock_name(data) do
    case Enum.find(data.slaves || [], fn {_name, station} ->
           station == data.dc_ref_station
         end) do
      {name, _station} -> name
      nil -> nil
    end
  end

  defp dc_cycle_ns(%{dc_config: %{cycle_ns: cycle_ns}})
       when is_integer(cycle_ns) and cycle_ns > 0,
       do: cycle_ns

  defp dc_cycle_ns(_data), do: nil

  defp lookup_slave_pid(name) do
    case Registry.lookup(EtherCAT.Registry, {:slave, name}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp slave_server(name), do: {:via, Registry, {EtherCAT.Registry, {:slave, name}}}

  defp bus_running? do
    is_pid(Process.whereis(Bus))
  end

  defp dc_running? do
    is_pid(Process.whereis(DC))
  end
end
