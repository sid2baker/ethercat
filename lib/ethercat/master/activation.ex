defmodule EtherCAT.Master.Activation do
  @moduledoc false

  require Logger

  alias EtherCAT.{Bus, DC}
  alias EtherCAT.DC.API, as: DCAPI
  alias EtherCAT.Domain.API, as: DomainAPI
  alias EtherCAT.Master.Config
  alias EtherCAT.Master.Status
  alias EtherCAT.Slave.API, as: SlaveAPI

  @activation_quiet_ms 2

  @spec activate_network(%EtherCAT.Master{}) ::
          {:ok, :preop_ready | :operational, %EtherCAT.Master{}}
          | {:activation_blocked, %EtherCAT.Master{}}
          | {:error, term(), %EtherCAT.Master{}}
  def activate_network(%{activatable_slaves: []} = data) do
    Logger.info("[Master] dynamic startup: slaves held in :preop for runtime configuration")

    case quiesce_bus() do
      :ok ->
        {:ok, :preop_ready, %{data | activation_failures: %{}}}

      {:error, reason} ->
        {:error, {:bus_not_ready, reason}, data}
    end
  end

  def activate_network(data) do
    Logger.info("[Master] activating — starting DC, cyclic domains, and advancing slaves to :op")

    case quiesce_bus() do
      :ok ->
        do_activate_network(data)

      {:error, reason} ->
        {:error, {:bus_not_ready, reason}, data}
    end
  end

  defp do_activate_network(data) do
    case start_dc_runtime(data) do
      {:ok, dc_data} ->
        with :ok <- start_domain_cycles(dc_data),
             :ok <- await_dc_lock_if_requested(dc_data) do
          activation_failures = activate_required_slaves(dc_data.activatable_slaves)

          activated_data = %{dc_data | activation_failures: activation_failures}

          if map_size(activation_failures) == 0 do
            {:ok, :operational, activated_data}
          else
            Logger.warning(
              "[Master] activation incomplete; blocked for #{inspect(Map.keys(activation_failures))}"
            )

            {:activation_blocked, activated_data}
          end
        else
          {:error, reason} ->
            {:error, reason, data}
        end

      {:error, reason} ->
        {:error, reason, data}
    end
  end

  @spec start_dc_runtime(%EtherCAT.Master{}) :: {:ok, %EtherCAT.Master{}} | {:error, term()}
  def start_dc_runtime(%{dc_ref_station: nil} = data), do: {:ok, %{data | dc_ref: nil}}

  def start_dc_runtime(data) do
    case DynamicSupervisor.start_child(
           EtherCAT.SessionSupervisor,
           {DC,
            bus: Bus,
            ref_station: data.dc_ref_station,
            monitored_stations: data.dc_stations,
            config: data.dc_config}
         ) do
      {:ok, pid} ->
        {:ok, %{data | dc_ref: Process.monitor(pid)}}

      {:error, {:already_started, pid}} ->
        {:ok, %{data | dc_ref: Process.monitor(pid)}}

      {:error, reason} ->
        {:error, {:dc_start_failed, reason}}
    end
  end

  defp start_domain_cycles(data) do
    Enum.reduce_while(Config.domain_ids(data.domain_configs || []), :ok, fn id, :ok ->
      case DomainAPI.start_cycling(id) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:domain_cycle_start_failed, id, reason}}}
      end
    end)
  end

  defp await_dc_lock_if_requested(%{dc_config: nil}), do: :ok

  defp await_dc_lock_if_requested(%{dc_config: %{await_lock?: false}}), do: :ok

  defp await_dc_lock_if_requested(data) do
    timeout_ms = data.dc_config.lock_timeout_ms

    if dc_running?() do
      case DCAPI.await_locked(DC, timeout_ms) do
        :ok ->
          :ok

        {:error, :timeout} ->
          {:error, {:dc_lock_timeout, Status.dc_status(data)}}

        {:error, reason} ->
          {:error, {:dc_lock_failed, reason}}
      end
    else
      {:error, {:dc_lock_unavailable, :no_active_dc_runtime}}
    end
  end

  defp activate_required_slaves(slave_names) do
    {safeop_ready, safeop_failures} =
      Enum.reduce(slave_names, {[], %{}}, fn name, {ready, failures} ->
        case SlaveAPI.request(name, :safeop) do
          :ok ->
            {[name | ready], failures}

          {:error, reason} ->
            Logger.warning("[Master] slave #{inspect(name)} → safeop failed: #{inspect(reason)}")
            {ready, Map.put(failures, name, {:safeop, reason})}
        end
      end)

    Enum.reduce(safeop_ready, safeop_failures, fn name, failures ->
      case SlaveAPI.request(name, :op) do
        :ok ->
          failures

        {:error, reason} ->
          Logger.warning("[Master] slave #{inspect(name)} → op failed: #{inspect(reason)}")
          Map.put(failures, name, {:op, reason})
      end
    end)
  end

  defp dc_running? do
    is_pid(Process.whereis(DC))
  end

  defp quiesce_bus do
    Bus.quiesce(Bus, @activation_quiet_ms)
  end
end
