defmodule EtherCAT.DC.Init do
  @moduledoc false

  require Logger

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.DC.InitPlan
  alias EtherCAT.DC.InitStep
  alias EtherCAT.DC.Snapshot
  alias EtherCAT.Slave.ESC.Registers
  alias EtherCAT.Utils

  @ethercat_epoch_offset_ns 946_684_800_000_000_000

  @spec initialize_clocks(Bus.server(), [{non_neg_integer(), binary()}]) ::
          {:ok, non_neg_integer(), [non_neg_integer()]} | {:error, term()}
  def initialize_clocks(bus, slave_topology) when slave_topology != [] do
    with :ok <- trigger_recv_latch(bus),
         {:ok, snapshots} <- read_snapshots(bus, slave_topology),
         {:ok, plan} <- InitPlan.build(snapshots, ethercat_now_ns()),
         :ok <- apply_init_plan(bus, plan) do
      Logger.debug(
        "[DC] initialized ref=0x#{Integer.to_string(plan.ref_station, 16)} dc_slaves=#{length(plan.steps)}"
      )

      {:ok, plan.ref_station, Enum.map(plan.steps, & &1.station)}
    end
  end

  def initialize_clocks(_bus, []), do: {:error, :no_slaves}

  defp trigger_recv_latch(bus) do
    Utils.expect_positive_wkc(
      Bus.transaction(bus, Transaction.bwr(Registers.dc_recv_time_latch())),
      :dc_latch_not_acknowledged,
      :dc_latch_unexpected_reply
    )
  end

  defp read_snapshots(bus, slave_topology) do
    Enum.reduce_while(slave_topology, {:ok, []}, fn {station, dl_status}, {:ok, acc} ->
      case read_snapshot(bus, station, dl_status) do
        {:ok, snapshot} -> {:cont, {:ok, [snapshot | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, snapshots_rev} -> {:ok, Enum.reverse(snapshots_rev)}
      {:error, _} = err -> err
    end
  end

  defp read_snapshot(bus, station, dl_status) do
    tx =
      Transaction.new()
      |> Transaction.fprd(station, Registers.dc_recv_time_ecat())
      |> Transaction.fprd(station, Registers.dc_recv_time(0))
      |> Transaction.fprd(station, Registers.dc_recv_time(1))
      |> Transaction.fprd(station, Registers.dc_recv_time(2))
      |> Transaction.fprd(station, Registers.dc_recv_time(3))
      |> Transaction.fprd(station, Registers.dc_speed_counter_start())

    case Bus.transaction(bus, tx) do
      {:ok, [%{wkc: 0} | _]} ->
        {:ok, Snapshot.new(station, dl_status, %{}, nil, nil)}

      {:ok, [ecat, p0, p1, p2, p3, speed_counter]} ->
        with {:ok, ecat_time_ns} <- decode_u64(station, :ecat_recv_time, ecat),
             {:ok, p0_time_ns} <- decode_u32(station, {:recv_time, 0}, p0),
             {:ok, p1_time_ns} <- decode_u32(station, {:recv_time, 1}, p1),
             {:ok, p2_time_ns} <- decode_u32(station, {:recv_time, 2}, p2),
             {:ok, p3_time_ns} <- decode_u32(station, {:recv_time, 3}, p3),
             {:ok, speed_counter_start} <-
               decode_u16(station, :speed_counter_start, speed_counter) do
          {:ok,
           Snapshot.new(
             station,
             dl_status,
             %{0 => p0_time_ns, 1 => p1_time_ns, 2 => p2_time_ns, 3 => p3_time_ns},
             ecat_time_ns,
             speed_counter_start
           )}
        end

      {:ok, results} ->
        {:error, {:dc_snapshot_unexpected_reply, station, length(results)}}

      {:error, reason} ->
        {:error, {:dc_snapshot_failed, station, reason}}
    end
  end

  defp decode_u64(_station, _field, %{data: <<value::64-little>>, wkc: 1}), do: {:ok, value}

  defp decode_u64(station, field, %{wkc: wkc}),
    do: {:error, {:dc_snapshot_read_failed, station, field, {:unexpected_wkc, wkc}}}

  defp decode_u32(_station, _field, %{data: <<value::32-little>>, wkc: 1}), do: {:ok, value}

  defp decode_u32(station, field, %{wkc: wkc}),
    do: {:error, {:dc_snapshot_read_failed, station, field, {:unexpected_wkc, wkc}}}

  defp decode_u16(_station, _field, %{data: <<value::16-little>>, wkc: 1}), do: {:ok, value}

  defp decode_u16(station, field, %{wkc: wkc}),
    do: {:error, {:dc_snapshot_read_failed, station, field, {:unexpected_wkc, wkc}}}

  defp apply_init_plan(bus, %InitPlan{steps: steps}) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case apply_init_step(bus, step) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp apply_init_step(bus, %InitStep{} = step) do
    tx =
      Transaction.new()
      |> Transaction.fpwr(step.station, Registers.dc_system_time_offset(step.offset_ns))
      |> Transaction.fpwr(step.station, Registers.dc_system_time_delay(step.delay_ns))

    with :ok <- write_timing_values(bus, step.station, tx),
         :ok <- reset_filter(bus, step) do
      :ok
    end
  end

  defp write_timing_values(bus, station, tx) do
    case Bus.transaction(bus, tx) do
      {:ok, [%{wkc: 1}, %{wkc: 1}]} ->
        :ok

      {:ok, [%{wkc: offset_wkc}, %{wkc: delay_wkc}]} ->
        {:error,
         {:dc_apply_failed, station, {:unexpected_wkc, %{offset: offset_wkc, delay: delay_wkc}}}}

      {:error, reason} ->
        {:error, {:dc_apply_failed, station, reason}}
    end
  end

  defp reset_filter(bus, %InitStep{} = step) do
    case Bus.transaction(
           bus,
           Transaction.fpwr(
             step.station,
             Registers.dc_speed_counter_start(step.speed_counter_start)
           )
         ) do
      {:ok, [%{wkc: 1}]} ->
        :ok

      {:ok, [%{wkc: wkc}]} ->
        {:error, {:dc_filter_reset_failed, step.station, {:unexpected_wkc, wkc}}}

      {:error, reason} ->
        {:error, {:dc_filter_reset_failed, step.station, reason}}
    end
  end

  defp ethercat_now_ns do
    System.os_time(:nanosecond) - @ethercat_epoch_offset_ns
  end
end
