defmodule EtherCAT.Master.Diagnostics do
  @moduledoc false

  alias EtherCAT.{Bus, DC, Domain}
  alias EtherCAT.DC.Status, as: DCStatus
  alias EtherCAT.Master.Status

  @spec status(Status.lifecycle(), %EtherCAT.Master{}) :: Status.t()
  def status(lifecycle, data) do
    Status.from_runtime(lifecycle, data, %{
      dc_status: dc_status(data),
      bus_status: bus_status(),
      configured_domains: configured_domains(data),
      configured_slaves: configured_slaves(data)
    })
  end

  @spec dc_status(%EtherCAT.Master{}) :: DCStatus.t()
  def dc_status(%{dc_config: nil}) do
    %DCStatus{lock_state: :disabled}
  end

  def dc_status(data) do
    base_status = %DCStatus{
      configured?: true,
      active?: false,
      cycle_ns: data.dc_config.cycle_ns,
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

  @spec slaves(%EtherCAT.Master{}) ::
          [
            %{
              name: atom(),
              station: non_neg_integer(),
              server: :gen_statem.server_ref(),
              pid: pid() | nil,
              fault: term() | nil
            }
          ]
  def slaves(data) do
    Enum.map(data.slaves, fn {name, station} ->
      %{
        name: name,
        station: station,
        server: slave_server(name),
        pid: lookup_slave_pid(name),
        fault: Map.get(data.slave_faults, name)
      }
    end)
  end

  @spec configured_slaves(%EtherCAT.Master{}) :: [Status.configured_slave()]
  def configured_slaves(data) do
    station_by_name = Map.new(data.slaves)

    Enum.map(data.slave_configs, fn config ->
      %{
        name: config.name,
        station: Map.get(station_by_name, config.name),
        server: slave_server(config.name),
        pid: lookup_slave_pid(config.name),
        driver: config.driver,
        config: config.config,
        target_state: config.target_state,
        process_data: config.process_data,
        health_poll_ms: config.health_poll_ms,
        fault: Map.get(data.slave_faults, config.name)
      }
    end)
  end

  @spec domains(%EtherCAT.Master{}) :: [{atom(), pos_integer(), pid()}]
  def domains(data) do
    data.domain_configs
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

  @spec configured_domains(%EtherCAT.Master{}) :: [Status.configured_domain()]
  def configured_domains(data) do
    Enum.map(data.domain_configs, fn config ->
      pid =
        case Registry.lookup(EtherCAT.Registry, {:domain, config.id}) do
          [{domain_pid, _}] -> domain_pid
          [] -> nil
        end

      live_cycle_time_us =
        case Domain.info(config.id) do
          {:ok, %{cycle_time_us: cycle_time_us}} when is_integer(cycle_time_us) ->
            cycle_time_us

          _other ->
            nil
        end

      %{
        id: config.id,
        configured_cycle_time_us: config.cycle_time_us,
        logical_base: config.logical_base,
        pid: pid,
        live_cycle_time_us: live_cycle_time_us
      }
    end)
  end

  @spec bus_public_ref(%EtherCAT.Master{}) :: Bus.server() | nil
  def bus_public_ref(_data) do
    if bus_running?(), do: Bus, else: nil
  end

  @spec bus_status() :: map() | nil
  def bus_status do
    if bus_running?() do
      case Bus.info(Bus) do
        {:ok, info} -> info
        _other -> nil
      end
    else
      nil
    end
  end

  defp reference_clock_name(%{dc_ref_station: nil}), do: nil

  defp reference_clock_name(data) do
    case Enum.find(data.slaves, fn {_name, station} ->
           station == data.dc_ref_station
         end) do
      {name, _station} -> name
      nil -> nil
    end
  end

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
