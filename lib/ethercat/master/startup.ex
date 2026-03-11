defmodule EtherCAT.Master.Startup do
  @moduledoc false

  require Logger

  alias EtherCAT.{Bus, Domain, Slave}
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.DC.API, as: DCAPI
  alias EtherCAT.Master.Config
  alias EtherCAT.Master.Config.DomainPlan
  alias EtherCAT.Master.Startup.InitRecovery
  alias EtherCAT.Master.Startup.Reset, as: InitReset
  alias EtherCAT.Master.Startup.Verification, as: InitVerification
  alias EtherCAT.Slave.ESC.Registers

  @frame_timeout_base_us 200
  @frame_timeout_per_slave_us 40
  @frame_timeout_host_floor_ms 2
  @frame_timeout_max_ms 10
  @init_poll_limit 100
  @init_poll_interval_ms 10
  @max_auto_increment_slaves 32_769
  @max_station_address 0xFFFF

  @spec tune_bus_frame_timeout(%EtherCAT.Master{}, non_neg_integer()) :: :ok
  def tune_bus_frame_timeout(data, slave_count) do
    if bus_running?() do
      target_ms = recommended_frame_timeout_ms(data, slave_count)

      case Bus.set_frame_timeout(Bus, target_ms) do
        :ok ->
          Logger.info(
            "[Master] bus frame timeout set to #{target_ms}ms (slaves=#{slave_count}, dc_cycle_ns=#{inspect(dc_cycle_ns(data))})"
          )

          :ok

        {:error, reason} ->
          Logger.warning(
            "[Master] failed to tune bus frame timeout to #{target_ms}ms: #{inspect(reason)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  @spec configure_network(%EtherCAT.Master{}) ::
          {:ok, %EtherCAT.Master{}} | {:error, term(), %EtherCAT.Master{}}
  def configure_network(data) do
    count = data.slave_count
    Logger.info("[Master] configuring #{count} slave(s)")

    with :ok <- validate_topology_addressing(data, count),
         {:ok, stations} <- assign_station_addresses(data, count),
         {:ok, slave_topology} <- read_topology_statuses(stations),
         :ok <- reset_slaves_to_init(stations),
         {:ok, dc_ref_station, dc_stations} <- initialize_distributed_clocks(data, slave_topology),
         {:ok, domain_refs} <- start_domains(data),
         {:ok, effective_slave_configs, slaves, pending_preop, activatable_slaves, slave_refs} <-
           start_slaves(data, count, if(dc_ref_station, do: dc_cycle_ns(data), else: nil)) do
      {:ok,
       %{
         data
         | dc_ref_station: dc_ref_station,
           dc_stations: dc_stations,
           slave_configs: effective_slave_configs,
           slaves: slaves,
           pending_preop: MapSet.new(pending_preop),
           activatable_slaves: activatable_slaves,
           activation_failures: %{},
           domain_refs: domain_refs,
           slave_refs: slave_refs
       }}
    else
      {:error, reason} ->
        {:error, reason, data}

      {:error, reason, started_slaves} ->
        {:error, reason, %{data | slaves: started_slaves}}
    end
  end

  @doc false
  @spec recommended_frame_timeout_ms(%EtherCAT.Master{}, non_neg_integer()) :: pos_integer()
  def recommended_frame_timeout_ms(%{frame_timeout_override_ms: timeout_ms}, _slave_count)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    timeout_ms
  end

  def recommended_frame_timeout_ms(data, slave_count)
      when is_integer(slave_count) and slave_count > 0 do
    topology_timeout_ms =
      @frame_timeout_base_us
      |> Kernel.+(slave_count * @frame_timeout_per_slave_us)
      |> ceil_div(1_000)

    cycle_cap_ms = cycle_relative_timeout_cap_ms(data)
    floor_ms = min(@frame_timeout_host_floor_ms, cycle_cap_ms)

    topology_timeout_ms
    |> max(floor_ms)
    |> min(cycle_cap_ms)
    |> min(@frame_timeout_max_ms)
  end

  def recommended_frame_timeout_ms(data, _slave_count) do
    min(@frame_timeout_host_floor_ms, cycle_relative_timeout_cap_ms(data))
  end

  @doc false
  @spec validate_topology_addressing(%EtherCAT.Master{}, non_neg_integer()) ::
          :ok | {:error, term()}
  def validate_topology_addressing(%{base_station: base_station}, slave_count)
      when is_integer(base_station) and is_integer(slave_count) and slave_count >= 0 do
    cond do
      slave_count > @max_auto_increment_slaves ->
        {:error,
         {:unsupported_topology,
          {:too_many_slaves_for_auto_increment, slave_count, @max_auto_increment_slaves}}}

      slave_count > 0 and base_station + slave_count - 1 > @max_station_address ->
        {:error,
         {:unsupported_topology,
          {:station_address_overflow, base_station, slave_count, @max_station_address}}}

      true ->
        :ok
    end
  end

  defp ceil_div(value, divisor) when is_integer(value) and is_integer(divisor) and divisor > 0 do
    div(value + divisor - 1, divisor)
  end

  defp cycle_relative_timeout_cap_ms(%{domain_configs: domain_configs})
       when is_list(domain_configs) and domain_configs != [] do
    domain_configs
    |> Enum.map(&domain_cycle_time_us/1)
    |> Enum.min()
    |> half_cycle_timeout_ms()
    |> min(@frame_timeout_max_ms)
    |> max(1)
  end

  defp cycle_relative_timeout_cap_ms(data) do
    case dc_cycle_ns(data) do
      cycle_ns when is_integer(cycle_ns) and cycle_ns > 0 ->
        cycle_ns
        |> div(1_000)
        |> half_cycle_timeout_ms()
        |> min(@frame_timeout_max_ms)
        |> max(1)

      _ ->
        @frame_timeout_max_ms
    end
  end

  defp domain_cycle_time_us(%DomainPlan{cycle_time_us: cycle_time_us}), do: cycle_time_us
  defp domain_cycle_time_us(%{cycle_time_us: cycle_time_us}), do: cycle_time_us

  defp half_cycle_timeout_ms(cycle_time_us)
       when is_integer(cycle_time_us) and cycle_time_us > 0 do
    cycle_time_us
    |> ceil_div(2)
    |> ceil_div(1_000)
  end

  defp station_for_position(data, pos), do: data.base_station + pos

  defp assign_station_addresses(data, count) do
    stations = Enum.map(0..(count - 1), &station_for_position(data, &1))

    result =
      Enum.reduce_while(0..(count - 1), :ok, fn pos, :ok ->
        station = station_for_position(data, pos)

        case Bus.transaction(Bus, Transaction.apwr(pos, Registers.station_address(station))) do
          {:ok, [%{wkc: 1}]} ->
            {:cont, :ok}

          {:ok, [%{wkc: wkc}]} ->
            {:halt, {:error, {:station_assign_failed, pos, station, {:unexpected_wkc, wkc}}}}

          {:error, reason} ->
            {:halt, {:error, {:station_assign_failed, pos, station, reason}}}
        end
      end)

    case result do
      :ok -> {:ok, stations}
      {:error, _} = err -> err
    end
  end

  defp read_topology_statuses(stations) do
    Enum.reduce_while(stations, {:ok, []}, fn station, {:ok, acc} ->
      case Bus.transaction(Bus, Transaction.fprd(station, Registers.dl_status())) do
        {:ok, [%{data: status, wkc: 1}]} ->
          {:cont, {:ok, [{station, status} | acc]}}

        {:ok, [%{wkc: wkc}]} ->
          {:halt, {:error, {:topology_read_failed, station, {:unexpected_wkc, wkc}}}}

        {:error, reason} ->
          {:halt, {:error, {:topology_read_failed, station, reason}}}
      end
    end)
    |> case do
      {:ok, topology_rev} -> {:ok, Enum.reverse(topology_rev)}
      {:error, _} = err -> err
    end
  end

  defp reset_slaves_to_init(stations) do
    count = length(stations)

    with :ok <- reset_slaves_to_default(count),
         :ok <- broadcast_init_ack(count),
         :ok <- verify_init_states(stations, @init_poll_limit) do
      :ok
    else
      {:error, _} = err ->
        err
    end
  end

  defp reset_slaves_to_default(count) do
    case Bus.transaction(Bus, InitReset.transaction()) do
      {:ok, replies} ->
        case InitReset.validate_results(replies, count) do
          :ok ->
            :ok

          {:error, wkcs, ^count} ->
            {:error, {:init_default_reset_failed, wkcs, count}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp broadcast_init_ack(count) do
    case Bus.transaction(Bus, Transaction.bwr(Registers.al_control(0x11))) do
      {:ok, replies} ->
        case InitReset.validate_init_ack_reply(replies, count) do
          :ok ->
            :ok

          {:partial, wkc, ^count} ->
            Logger.warning(
              "[Master] partial broadcast init-ack response during reset: wkc=#{wkc} expected<=#{count}; continuing with per-station init verification"
            )

            :ok

          {:error, {:unexpected_wkc, _, _} = reason} ->
            {:error, {:init_reset_failed, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp verify_init_states(_stations, 0), do: {:error, :init_verification_exhausted}

  defp verify_init_states(stations, attempts_left) do
    statuses = Enum.map(stations, &read_init_status/1)
    blocking = InitVerification.blocking_statuses(statuses)

    if blocking == [] do
      log_lingering_init_errors(InitVerification.lingering_error_statuses(statuses))
      :ok
    else
      if attempts_left == 1 do
        {:error, {:init_verification_failed, blocking}}
      else
        with :ok <- recover_init_states(blocking) do
          Process.sleep(@init_poll_interval_ms)
          verify_init_states(stations, attempts_left - 1)
        end
      end
    end
  end

  defp recover_init_states(statuses) do
    statuses
    |> InitRecovery.actions()
    |> Enum.reduce_while(:ok, fn
      {:ack_error, station, control}, :ok ->
        case write_al_control(station, control) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:init_recovery_failed, station, reason}}}
        end

      {:request_init, station, control}, :ok ->
        case write_al_control(station, control) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:init_recovery_failed, station, reason}}}
        end
    end)
  end

  defp write_al_control(station, control) do
    case Bus.transaction(Bus, Transaction.fpwr(station, Registers.al_control(control))) do
      {:ok, [%{wkc: 1}]} -> :ok
      {:ok, [%{wkc: wkc}]} -> {:error, {:unexpected_wkc, wkc}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_init_status(station) do
    case Bus.transaction(Bus, Transaction.fprd(station, Registers.al_status())) do
      {:ok, [%{data: <<_::3, error::1, state::4, _::8>>, wkc: 1}]} ->
        %{
          station: station,
          state: state,
          error: error,
          error_code: if(error == 1, do: read_al_status_code(station), else: nil)
        }

      {:ok, [%{wkc: wkc}]} ->
        %{station: station, state: nil, error: nil, error_code: nil, wkc: wkc}

      {:error, reason} ->
        %{station: station, state: nil, error: nil, error_code: nil, error_reason: reason}
    end
  end

  defp read_al_status_code(station) do
    case Bus.transaction(Bus, Transaction.fprd(station, Registers.al_status_code())) do
      {:ok, [%{data: <<code::16-little>>, wkc: 1}]} -> code
      _ -> nil
    end
  end

  defp log_lingering_init_errors([]), do: :ok

  defp log_lingering_init_errors(statuses) do
    Logger.debug(
      "[Master] continuing with slaves in INIT but with AL error latched: #{inspect(statuses)}"
    )
  end

  defp initialize_distributed_clocks(%{dc_config: nil}, _slave_topology) do
    {:ok, nil, []}
  end

  defp initialize_distributed_clocks(_data, slave_topology) do
    case DCAPI.initialize_clocks(Bus, slave_topology) do
      {:ok, ref_station, dc_stations} ->
        Logger.info("[Master] DC initialized, ref=0x#{Integer.to_string(ref_station, 16)}")
        {:ok, ref_station, dc_stations}

      {:error, :no_dc_capable_slave} ->
        Logger.debug("[Master] no DC-capable slaves found — running without DC")
        {:ok, nil, []}

      {:error, reason} ->
        Logger.warning("[Master] DC init failed (#{inspect(reason)}) — running without DC")
        {:ok, nil, []}
    end
  end

  defp start_domains(data) do
    Enum.reduce_while(data.domain_configs || [], {:ok, %{}}, fn entry, {:ok, refs} ->
      domain_opts = Config.domain_start_opts(entry)
      id = entry.id

      case DynamicSupervisor.start_child(
             EtherCAT.SessionSupervisor,
             {Domain, [{:bus, Bus} | domain_opts]}
           ) do
        {:ok, pid} ->
          {:cont, {:ok, Map.put(refs, Process.monitor(pid), id)}}

        {:error, {:already_started, pid}} ->
          {:cont, {:ok, Map.put(refs, Process.monitor(pid), id)}}

        {:error, reason} ->
          {:halt, {:error, {:domain_start_failed, id, reason}}}
      end
    end)
  end

  defp start_slaves(data, bus_count, dc_cycle_ns) do
    with {:ok, effective_config} <-
           Config.effective_slave_config(data.slave_configs || [], bus_count) do
      Enum.with_index(effective_config)
      |> Enum.reduce_while(
        {:ok, [], [], [], %{}},
        fn {entry, pos}, {:ok, slave_acc, pending_acc, activatable_acc, slave_refs} ->
          station = station_for_position(data, pos)
          name = entry.name

          opts = [
            bus: Bus,
            station: station,
            name: name,
            driver: entry.driver,
            config: entry.config,
            process_data: entry.process_data,
            dc_cycle_ns: dc_cycle_ns,
            sync: entry.sync,
            health_poll_ms: entry.health_poll_ms
          ]

          case DynamicSupervisor.start_child(EtherCAT.SlaveSupervisor, {Slave, opts}) do
            {:ok, pid} ->
              next_activatable =
                if entry.target_state == :op do
                  [name | activatable_acc]
                else
                  activatable_acc
                end

              {:cont,
               {:ok, [{name, station} | slave_acc], [name | pending_acc], next_activatable,
                Map.put(slave_refs, Process.monitor(pid), name)}}

            {:error, reason} ->
              {:halt,
               {:error, {:slave_start_failed, name, station, reason}, Enum.reverse(slave_acc)}}
          end
        end
      )
      |> case do
        {:ok, slaves, pending, activatable, slave_refs} ->
          {:ok, effective_config, Enum.reverse(slaves), Enum.reverse(pending),
           Enum.reverse(activatable), slave_refs}

        {:error, reason, started_slaves} ->
          {:error, reason, started_slaves}

        {:error, _} = err ->
          err
      end
    end
  end

  defp dc_cycle_ns(%{dc_config: %{cycle_ns: cycle_ns}})
       when is_integer(cycle_ns) and cycle_ns > 0,
       do: cycle_ns

  defp dc_cycle_ns(_data), do: nil

  defp bus_running? do
    is_pid(Process.whereis(Bus))
  end
end
