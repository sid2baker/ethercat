defmodule EtherCAT.DC do
  @moduledoc """
  Distributed Clocks — clock initialization and ongoing drift maintenance.

  ## Initialization

  `DC.initialize_clocks/2` performs the one-time clock synchronization sequence described in
  ETG.1000 §9.1.3.6:

  1. Trigger receive-time latch on all slaves (BWR to 0x0900).
  2. Read one DC snapshot per slave:
     - DL-status-derived active ports
     - receive time port 0..3
     - ECAT receive time
     - speed counter start
  3. Identify the reference clock (first DC-capable slave in bus order).
  4. Build a deterministic init plan:
     - chain-only propagation delay estimate from latched receive spans
     - per-slave system time offset against the EtherCAT epoch
     - PLL filter reset value
  5. Apply offset + delay writes to every DC-capable slave.
  6. Reset PLL filters by writing back the latched speed-counter seed.

  The planning step is pure and testable via `EtherCAT.DC.InitPlan.build/2`.
  The current topology model is intentionally explicit: it supports a linear
  bus ordered by scan position. More complex tree-delay propagation needs a
  richer topology graph than the current master passes into DC init.

  ## Drift maintenance

  After `start_link/1`, the gen_statem sends one ARMW datagram to the system
  time register (0x0910) of the reference clock every `period_ms` milliseconds.
  The EtherCAT frame passes through each slave in order — the reference clock's
  system time is read and written to every subsequent slave in a single pass,
  keeping all clocks aligned.
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.DC.InitPlan
  alias EtherCAT.DC.InitStep
  alias EtherCAT.DC.Snapshot
  alias EtherCAT.Slave.Registers
  alias EtherCAT.Telemetry

  # ns between Unix epoch (1970) and EtherCAT epoch (2000-01-01 00:00:00)
  @ethercat_epoch_offset_ns 946_684_800_000_000_000

  # -- Public API ------------------------------------------------------------

  @doc """
  One-time DC initialization. Must be called after `assign_stations` and before
  `start_slaves`.

  `slave_topology` is a list of `{station, dl_status_binary}` tuples — one per
  slave, in bus order. DL status is a 2-byte little-endian value from register
  0x0110, used to determine which ports are open (topology).

  Returns `{:ok, ref_station}` where `ref_station` is the station address of
  the reference clock slave, or `{:error, reason}`.
  """
  @spec initialize_clocks(Bus.server(), [{non_neg_integer(), binary()}]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def initialize_clocks(bus, slave_topology) when slave_topology != [] do
    with :ok <- trigger_recv_latch(bus),
         {:ok, snapshots} <- read_snapshots(bus, slave_topology),
         {:ok, plan} <- InitPlan.build(snapshots, ethercat_now_ns()),
         :ok <- apply_init_plan(bus, plan) do
      Logger.debug(
        "[DC] initialized ref=0x#{Integer.to_string(plan.ref_station, 16)} dc_slaves=#{length(plan.steps)}"
      )

      {:ok, plan.ref_station}
    end
  end

  def initialize_clocks(_link, []), do: {:error, :no_slaves}

  # -- child_spec / start_link -----------------------------------------------

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc """
  Start the DC drift maintenance gen_statem.

  Options:
    - `:bus` (required) — Bus server reference
    - `:ref_station` (required) — station address of the reference clock
    - `:period_ms` — drift correction interval, default 10 ms
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    :gen_statem.start_link({:local, __MODULE__}, __MODULE__, opts, [])
  end

  # -- :gen_statem callbacks -------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    bus = Keyword.fetch!(opts, :bus)
    ref_station = Keyword.fetch!(opts, :ref_station)
    period_ms = Keyword.get(opts, :period_ms, 10)

    data = %{bus: bus, ref_station: ref_station, period_ms: period_ms, fail_count: 0}
    {:ok, :running, data}
  end

  @impl true
  def handle_event(:enter, _old, :running, data) do
    {:keep_state_and_data, [{:state_timeout, data.period_ms, :tick}]}
  end

  def handle_event(:enter, _old, :stopped, _data), do: :keep_state_and_data

  def handle_event(:state_timeout, :tick, :running, data) do
    result =
      Bus.transaction(
        data.bus,
        Transaction.armw(data.ref_station, Registers.dc_system_time()),
        drift_tick_timeout_us(data.period_ms)
      )

    new_data =
      case result do
        {:ok, [%{wkc: wkc}]} ->
          if data.fail_count > 0 do
            Logger.info("[DC] drift tick recovered after #{data.fail_count} failure(s)")
          end

          Telemetry.dc_tick(data.ref_station, wkc)

          %{data | fail_count: 0}

        {:error, reason} ->
          n = data.fail_count + 1

          if n == 1 or rem(n, 100) == 0 do
            Logger.warning("[DC] drift tick failed: #{inspect(reason)} (#{n} consecutive)")
          end

          %{data | fail_count: n}
      end

    {:keep_state, new_data, [{:state_timeout, data.period_ms, :tick}]}
  end

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # -- Init helpers ----------------------------------------------------------

  defp trigger_recv_latch(bus) do
    case Bus.transaction(bus, Transaction.bwr(Registers.dc_recv_time_latch())) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 -> :ok
      {:ok, [%{wkc: 0}]} -> {:error, :dc_latch_not_acknowledged}
      {:ok, _results} -> {:error, :dc_latch_unexpected_reply}
      {:error, _} = err -> err
    end
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

  defp drift_tick_timeout_us(period_ms) when is_integer(period_ms) and period_ms > 0 do
    period_us = period_ms * 1_000
    max(div(period_us * 9, 10), 200)
  end
end
