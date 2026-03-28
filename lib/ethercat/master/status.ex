defmodule EtherCAT.Master.Status do
  @moduledoc """
  Stable machine-readable master runtime status.
  """

  alias EtherCAT.Backend
  alias EtherCAT.{Bus, DC, Domain}
  alias EtherCAT.DC.Status, as: DCStatus

  @type lifecycle ::
          :stopped
          | :idle
          | :discovering
          | :awaiting_preop
          | :preop_ready
          | :deactivated
          | :operational
          | :activation_blocked
          | :recovering

  @type configured_domain :: %{
          id: atom(),
          configured_cycle_time_us: pos_integer(),
          logical_base: non_neg_integer(),
          pid: pid() | nil,
          live_cycle_time_us: pos_integer() | nil
        }

  @type configured_slave :: %{
          name: atom(),
          station: non_neg_integer() | nil,
          server: :gen_statem.server_ref(),
          pid: pid() | nil,
          driver: module(),
          target_state: :preop | :op,
          process_data: term(),
          health_poll_ms: pos_integer() | nil,
          fault: term() | nil
        }

  @type t :: %__MODULE__{
          lifecycle: lifecycle(),
          desired_target: :preop | :safeop | :op | nil,
          backend: Backend.t() | nil,
          configured_domains: [configured_domain()],
          configured_slaves: [configured_slave()],
          runtime_faults: %{optional(term()) => term()},
          activation_failures: %{optional(term()) => term()},
          slave_faults: %{optional(term()) => term()},
          bus_status: map() | nil,
          dc_status: DCStatus.t(),
          reference_clock: %{name: atom() | nil, station: non_neg_integer()} | nil,
          last_failure: map() | nil
        }

  defstruct lifecycle: :stopped,
            desired_target: nil,
            backend: nil,
            configured_domains: [],
            configured_slaves: [],
            runtime_faults: %{},
            activation_failures: %{},
            slave_faults: %{},
            bus_status: nil,
            dc_status: %DCStatus{lock_state: :disabled},
            reference_clock: nil,
            last_failure: nil

  @spec stopped() :: t()
  def stopped, do: %__MODULE__{}

  @spec from_runtime(lifecycle(), %EtherCAT.Master{}) :: t()
  def from_runtime(lifecycle, data) do
    dc_status = dc_status(data)

    %__MODULE__{
      lifecycle: lifecycle,
      desired_target: desired_target(data),
      backend: Map.get(data, :backend),
      configured_domains: configured_domains(data),
      configured_slaves: configured_slaves(data),
      runtime_faults: data.runtime_faults || %{},
      activation_failures: data.activation_failures || %{},
      slave_faults: data.slave_faults || %{},
      bus_status: bus_status(),
      dc_status: dc_status,
      reference_clock: reference_clock(dc_status),
      last_failure: data.last_failure
    }
  end

  @spec desired_runtime_target(%EtherCAT.Master{}) :: :op | :safeop | :preop
  def desired_runtime_target(%{desired_runtime_target: target})
      when target in [:op, :safeop, :preop] do
    target
  end

  def desired_runtime_target(_data), do: :op

  @spec desired_target(%EtherCAT.Master{}) :: :op | :safeop | :preop | nil
  def desired_target(%{desired_runtime_target: target}) when target in [:op, :safeop, :preop],
    do: target

  def desired_target(_data), do: nil

  @spec desired_public_state(%EtherCAT.Master{}) :: :preop_ready | :deactivated | :operational
  def desired_public_state(data) do
    case desired_runtime_target(data) do
      :op -> :operational
      :safeop -> :deactivated
      :preop -> :preop_ready
    end
  end

  @spec activation_blocked_reply(%EtherCAT.Master{}) :: {:error, term()}
  def activation_blocked_reply(data) do
    activation_failures = data.activation_failures
    runtime_faults = data.runtime_faults
    desired_target = desired_runtime_target(data)

    cond do
      map_size(activation_failures) > 0 and map_size(runtime_faults) == 0 ->
        activation_blocked_transition_reply(desired_target, activation_failures)

      map_size(activation_failures) == 0 and map_size(runtime_faults) > 0 ->
        {:error, {:runtime_degraded, runtime_faults}}

      true ->
        activation_blocked_combined_reply(desired_target, activation_failures, runtime_faults)
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
    slave_fault_count = map_size(data.slave_faults)

    "target=#{desired_runtime_target(data)} activation_failures=#{activation_count} runtime_faults=#{runtime_count} slave_faults=#{slave_fault_count}"
  end

  @spec recovering_summary(%EtherCAT.Master{}) :: String.t()
  def recovering_summary(data) do
    "target=#{desired_runtime_target(data)} runtime_faults=#{map_size(data.runtime_faults)} activation_failures=#{map_size(data.activation_failures)} slave_faults=#{map_size(data.slave_faults)}"
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

  @spec configured_slaves(%EtherCAT.Master{}) :: [configured_slave()]
  def configured_slaves(data) do
    station_by_name = Map.new(data.slaves || [])

    Enum.map(data.slave_configs || [], fn config ->
      %{
        name: config.name,
        station: Map.get(station_by_name, config.name),
        server: slave_server(config.name),
        pid: lookup_slave_pid(config.name),
        driver: config.driver,
        target_state: config.target_state,
        process_data: config.process_data,
        health_poll_ms: config.health_poll_ms,
        fault: Map.get(data.slave_faults, config.name)
      }
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

  @spec configured_domains(%EtherCAT.Master{}) :: [configured_domain()]
  def configured_domains(data) do
    Enum.map(data.domain_configs || [], fn config ->
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

  defp reference_clock(%DCStatus{} = dc_status) do
    case reference_clock_reply(dc_status) do
      {:ok, reference_clock} -> reference_clock
      {:error, _reason} -> nil
    end
  end

  defp bus_running? do
    is_pid(Process.whereis(Bus))
  end

  defp dc_running? do
    is_pid(Process.whereis(DC))
  end

  defp activation_blocked_transition_reply(:op, activation_failures) do
    {:error, {:activation_failed, activation_failures}}
  end

  defp activation_blocked_transition_reply(target, activation_failures) do
    {:error, {:deactivation_failed, target, activation_failures}}
  end

  defp activation_blocked_combined_reply(:op, activation_failures, runtime_faults) do
    {:error,
     {:activation_blocked,
      %{activation_failures: activation_failures, runtime_faults: runtime_faults}}}
  end

  defp activation_blocked_combined_reply(target, activation_failures, runtime_faults) do
    {:error,
     {:target_blocked,
      %{
        target: target,
        activation_failures: activation_failures,
        runtime_faults: runtime_faults
      }}}
  end
end
