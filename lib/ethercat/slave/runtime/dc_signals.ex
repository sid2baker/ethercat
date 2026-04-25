defmodule EtherCAT.Slave.Runtime.DCSignals do
  @moduledoc false

  require Logger

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.DC.Runtime, as: DCRuntime
  alias EtherCAT.Driver
  alias EtherCAT.Slave
  alias EtherCAT.Slave.ESC.Registers
  alias EtherCAT.Slave.Sync.Plan
  alias EtherCAT.Utils

  @spec configure(%Slave{}) :: {:ok, %Slave{}} | {:error, term(), %Slave{}}
  def configure(%{dc_cycle_ns: nil} = data), do: {:ok, clear_latch_config(data)}

  def configure(data) do
    case data.sync_config do
      nil ->
        {:ok, clear_latch_config(data)}

      sync_config ->
        with {:ok, local_time_ns, sync_diff_ns} <- read_sync_snapshot(data, sync_config),
             {:ok, plan} <-
               Plan.build(sync_config, data.dc_cycle_ns, local_time_ns, sync_diff_ns),
             {:ok, replies} <- send_sync_plan(data, plan),
             :ok <- Utils.ensure_expected_wkcs(replies, 1, :dc_configuration_failed) do
          next_data = apply_sync_plan(data, plan)

          Logger.debug(
            "[Slave #{data.name}] DC configured: mode=#{inspect(plan.mode)} cycle=#{inspect(plan.sync0_cycle_ns)}ns sync1_offset=#{plan.sync1_cycle_ns}ns start=#{inspect(plan.start_time_ns)} sync_diff=#{inspect(plan.sync_diff_ns)}ns latches=#{inspect(next_data.active_latches)}"
          )

          {:ok, next_data}
        else
          {:error, reason} ->
            {:error, reason, clear_latch_config(data)}
        end
    end
  end

  @spec poll_latches(%Slave{}) :: :ok
  def poll_latches(%{active_latches: nil}), do: :ok

  def poll_latches(data) do
    case Bus.transaction(
           data.bus,
           Transaction.fprd(data.station, Registers.dc_latch_event_status()),
           latch_poll_timeout_us(data)
         ) do
      {:ok, [%{data: <<latch0_status::8, latch1_status::8>>, wkc: wkc}]} when wkc > 0 ->
        dispatch_latch_events(data, latch0_status, latch1_status)

      _ ->
        :ok
    end
  end

  defp clear_latch_config(data) do
    %{data | active_latches: nil, latch_names: %{}, latch_poll_ms: nil}
  end

  defp dispatch_latch_events(data, latch0_status, latch1_status) do
    Enum.each(data.active_latches, fn {latch_id, edge} = key ->
      status = if latch_id == 0, do: latch0_status, else: latch1_status

      if latch_event_captured?(status, edge) do
        case read_latch_timestamp(data, latch_id, edge) do
          {:ok, timestamp_ns} ->
            case Map.get(data.latch_names, key) do
              nil ->
                :ok

              latch_name ->
                msg = {:ethercat, :latch, data.name, latch_name, timestamp_ns}

                data.subscriptions
                |> Map.get(latch_name, MapSet.new())
                |> Enum.each(&send(&1, msg))
            end

            invoke_driver_on_latch(data, latch_id, edge, timestamp_ns)

          :error ->
            :ok
        end
      end
    end)
  end

  defp invoke_driver_on_latch(%{driver: nil}, _latch_id, _edge, _timestamp_ns), do: :ok

  defp invoke_driver_on_latch(data, latch_id, edge, timestamp_ns) do
    Driver.Latch.on_latch(data.driver, data.name, data.config, latch_id, edge, timestamp_ns)
  end

  defp latch_event_captured?(status, :pos) do
    <<_::6, _neg::1, pos::1>> = <<status>>
    pos == 1
  end

  defp latch_event_captured?(status, :neg) do
    <<_::6, neg::1, _pos::1>> = <<status>>
    neg == 1
  end

  defp read_latch_timestamp(data, latch_id, edge) do
    reg = latch_time_register(latch_id, edge)

    case Bus.transaction(
           data.bus,
           Transaction.fprd(data.station, reg),
           latch_poll_timeout_us(data)
         ) do
      {:ok, [%{data: <<timestamp_ns::64-little>>, wkc: wkc}]} when wkc > 0 ->
        {:ok, timestamp_ns}

      _ ->
        :error
    end
  end

  defp latch_time_register(0, :pos), do: Registers.dc_latch0_pos_time()
  defp latch_time_register(0, :neg), do: Registers.dc_latch0_neg_time()
  defp latch_time_register(1, :pos), do: Registers.dc_latch1_pos_time()
  defp latch_time_register(1, :neg), do: Registers.dc_latch1_neg_time()

  defp read_sync_snapshot(_data, %{mode: mode}) when mode in [nil, :free_run],
    do: {:ok, nil, nil}

  defp read_sync_snapshot(data, _sync_config) do
    station = data.station

    snapshot_tx =
      Transaction.new()
      |> Transaction.fprd(station, Registers.dc_system_time())
      |> Transaction.fprd(station, Registers.dc_system_time_diff())

    case Bus.transaction(data.bus, snapshot_tx) do
      {:ok,
       [%{data: <<local_time_ns::64-little>>, wkc: 1}, %{data: <<raw_diff::32-little>>, wkc: 1}]} ->
        {:ok, local_time_ns, DCRuntime.decode_abs_sync_diff(raw_diff)}

      {:ok, [%{wkc: wkc}, _]} ->
        {:error,
         {:dc_configuration_failed, {:dc_snapshot_failed, :system_time, {:unexpected_wkc, wkc}}}}

      {:ok, [_, %{wkc: wkc}]} ->
        {:error,
         {:dc_configuration_failed, {:dc_snapshot_failed, :sync_diff, {:unexpected_wkc, wkc}}}}

      {:ok, replies} ->
        {:error,
         {:dc_configuration_failed, {:dc_snapshot_failed, {:unexpected_replies, replies}}}}

      {:error, reason} ->
        {:error, {:dc_configuration_failed, {:dc_snapshot_failed, reason}}}
    end
  end

  defp send_sync_plan(data, %Plan{} = plan) do
    station = data.station

    tx =
      Transaction.new()
      |> Transaction.fpwr(station, Registers.dc_activation(0x00))
      |> append_sync_timing(station, plan)
      |> Transaction.fpwr(station, Registers.dc_latch0_control(plan.latch0_control))
      |> Transaction.fpwr(station, Registers.dc_latch1_control(plan.latch1_control))
      |> Transaction.fpwr(
        station,
        Registers.dc_cyclic_unit_control(plan.cyclic_unit_control)
      )
      |> Transaction.fpwr(station, Registers.dc_activation(plan.activation))

    case Bus.transaction(data.bus, tx) do
      {:ok, replies} -> {:ok, replies}
      {:error, reason} -> {:error, {:dc_configuration_failed, reason}}
    end
  end

  defp append_sync_timing(tx, _station, %Plan{start_time_ns: nil}), do: tx

  defp append_sync_timing(tx, station, %Plan{} = plan) do
    tx
    |> Transaction.fpwr(station, Registers.dc_sync0_cycle_time(plan.sync0_cycle_ns))
    |> Transaction.fpwr(station, Registers.dc_sync1_cycle_time(plan.sync1_cycle_ns))
    |> Transaction.fpwr(station, Registers.dc_pulse_length(plan.pulse_ns))
    |> Transaction.fpwr(station, Registers.dc_sync0_start_time(plan.start_time_ns))
  end

  defp apply_sync_plan(data, %Plan{} = plan) do
    active_latches =
      case plan.active_latches do
        [] -> nil
        latches -> latches
      end

    latch_poll_ms = if active_latches, do: 1, else: nil

    %{
      data
      | active_latches: active_latches,
        latch_names: plan.latch_names,
        latch_poll_ms: latch_poll_ms
    }
  end

  defp latch_poll_timeout_us(%{latch_poll_ms: poll_ms, dc_cycle_ns: dc_cycle_ns})
       when is_integer(poll_ms) and poll_ms > 0 do
    poll_budget_us = div(poll_ms * 1_000 * 9, 10)

    cycle_budget_us =
      case dc_cycle_ns do
        cycle_ns when is_integer(cycle_ns) and cycle_ns > 0 ->
          div(cycle_ns * 9, 10)

        _ ->
          poll_budget_us
      end

    max(min(poll_budget_us, cycle_budget_us), 200)
  end

  defp latch_poll_timeout_us(_data), do: 900
end
