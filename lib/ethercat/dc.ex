defmodule EtherCAT.DC do
  @moduledoc """
  Distributed Clocks — clock initialization and runtime maintenance.

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

  The planning step is pure and covered by unit tests.
  The current topology model is intentionally explicit: it supports a linear
  bus ordered by scan position. More complex tree-delay propagation needs a
  richer topology graph than the current master passes into DC init.

  ## Runtime maintenance

  `EtherCAT.DC` is the runtime owner for network-wide Distributed Clocks state.
  It sends its own realtime frame at the configured DC cycle:

    - every tick: configured-address FRMW to the reference clock system time register (`0x0910`)
    - every N ticks: append configured-address reads of `0x092C` on the monitored DC-capable slaves

  That keeps DC ownership out of `Domain`. Domains stay process-image/LRW loops;
  `DC` owns clock maintenance, lock classification, diagnostics, and waiters.
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.DC.InitPlan
  alias EtherCAT.DC.InitStep
  alias EtherCAT.DC.Snapshot
  alias EtherCAT.DC.Status
  alias EtherCAT.Slave.Registers
  alias EtherCAT.Telemetry

  @ethercat_epoch_offset_ns 946_684_800_000_000_000
  @default_diagnostic_interval_ns 10_000_000

  @doc """
  One-time DC initialization. Must be called after `assign_stations` and before
  `start_slaves`.

  `slave_topology` is a list of `{station, dl_status_binary}` tuples — one per
  slave, in bus order. DL status is a 2-byte little-endian value from register
  `0x0110`, used to determine which ports are open.

  Returns `{:ok, ref_station, monitored_stations}` where `ref_station` is the
  reference-clock station and `monitored_stations` is the ordered list of
  DC-capable stations whose `0x092C` sync-diff registers can be checked at
  runtime, or `{:error, reason}`.
  """
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

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5000
    }
  end

  @doc """
  Start the DC runtime maintenance process.

  Options:
    - `:bus` (required)
    - `:ref_station` (required)
    - `:config` (required) — `%EtherCAT.DC.Config{}`
    - `:monitored_stations` — ordered DC-capable stations for `0x092C` diagnostics
    - `:tick_interval_ms` — optional runtime tick override for tests/debugging
    - `:diagnostic_interval_cycles` — optional diagnostic cadence override for tests/debugging
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    :gen_statem.start_link({:local, __MODULE__}, __MODULE__, opts, [])
  end

  @doc "Return a runtime Distributed Clocks status snapshot."
  @spec status(:gen_statem.server_ref()) :: Status.t() | {:error, :not_running}
  def status(server \\ __MODULE__) do
    try do
      :gen_statem.call(server, :status)
    catch
      :exit, _reason -> {:error, :not_running}
    end
  end

  @doc "Block until the DC runtime reports `:locked`."
  @spec await_locked(:gen_statem.server_ref(), pos_integer()) :: :ok | {:error, term()}
  def await_locked(server \\ __MODULE__, timeout_ms \\ 5_000)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_await_locked(server, deadline_ms)
  end

  @doc false
  @spec maintenance_transaction(non_neg_integer()) :: Transaction.t()
  def maintenance_transaction(ref_station) when is_integer(ref_station) and ref_station >= 0 do
    Transaction.frmw(ref_station, Registers.dc_system_time())
  end

  @doc false
  @spec decode_abs_sync_diff(non_neg_integer()) :: non_neg_integer()
  def decode_abs_sync_diff(raw) when is_integer(raw) and raw >= 0 do
    <<_::1, abs_sync_diff_ns::31>> = <<raw::32>>
    abs_sync_diff_ns
  end

  @doc false
  @spec classify_lock([non_neg_integer()], pos_integer()) ::
          {:locking | :locked | :unavailable, non_neg_integer() | nil}
  def classify_lock([], _threshold_ns), do: {:unavailable, nil}

  def classify_lock(sync_diffs, threshold_ns)
      when is_list(sync_diffs) and is_integer(threshold_ns) and threshold_ns > 0 do
    max_sync_diff_ns = Enum.max(sync_diffs)

    if max_sync_diff_ns <= threshold_ns do
      {:locked, max_sync_diff_ns}
    else
      {:locking, max_sync_diff_ns}
    end
  end

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    bus = Keyword.fetch!(opts, :bus)
    ref_station = Keyword.fetch!(opts, :ref_station)
    config = Keyword.fetch!(opts, :config)
    monitored_stations = Keyword.get(opts, :monitored_stations, [ref_station])
    tick_interval_ms = Keyword.get(opts, :tick_interval_ms, tick_interval_ms(config.cycle_ns))

    diagnostic_interval_cycles =
      Keyword.get(opts, :diagnostic_interval_cycles, diagnostic_interval_cycles(config.cycle_ns))

    data = %{
      bus: bus,
      ref_station: ref_station,
      config: config,
      monitored_stations: monitored_stations,
      tick_interval_ms: tick_interval_ms,
      diagnostic_interval_cycles: diagnostic_interval_cycles,
      cycle_count: 0,
      fail_count: 0,
      lock_state: initial_lock_state(monitored_stations),
      max_sync_diff_ns: nil,
      last_sync_check_at_ms: nil
    }

    {:ok, :running, data}
  end

  @impl true
  def handle_event(:enter, _old, :running, data) do
    {:keep_state_and_data, [{:state_timeout, data.tick_interval_ms, :tick}]}
  end

  def handle_event({:call, from}, :status, :running, data) do
    {:keep_state_and_data, [{:reply, from, runtime_status(data)}]}
  end

  def handle_event(:state_timeout, :tick, :running, data) do
    request = build_runtime_request(data)

    updated_data =
      case Bus.transaction(data.bus, request.tx, tick_timeout_us(data.config.cycle_ns)) do
        {:ok, replies} ->
          process_runtime_replies(data, request, replies)

        {:error, reason} ->
          process_runtime_failure(data, request, reason)
      end

    {:keep_state, %{updated_data | cycle_count: data.cycle_count + 1},
     [{:state_timeout, data.tick_interval_ms, :tick}]}
  end

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  defp build_runtime_request(data) do
    diagnostics? =
      data.monitored_stations != [] and
        rem(data.cycle_count + 1, data.diagnostic_interval_cycles) == 0

    tx =
      data.ref_station
      |> maintenance_transaction()
      |> maybe_append_sync_diff_reads(diagnostics?, data.monitored_stations)

    %{tx: tx, diagnostics?: diagnostics?}
  end

  defp maybe_append_sync_diff_reads(tx, false, _stations), do: tx

  defp maybe_append_sync_diff_reads(tx, true, stations) do
    Enum.reduce(stations, tx, fn station, acc ->
      Transaction.fprd(acc, station, Registers.dc_system_time_diff())
    end)
  end

  defp process_runtime_replies(data, %{diagnostics?: false}, [%{wkc: wkc}]) when wkc > 0 do
    maybe_log_runtime_recovered(data.fail_count)
    Telemetry.dc_tick(data.ref_station, wkc)
    %{data | fail_count: 0}
  end

  defp process_runtime_replies(data, %{diagnostics?: true}, [%{wkc: wkc} | diag_replies])
       when wkc > 0 do
    case decode_sync_diffs(data.monitored_stations, diag_replies, []) do
      {:ok, sync_diffs} ->
        maybe_log_runtime_recovered(data.fail_count)
        Telemetry.dc_tick(data.ref_station, wkc)

        now_ms = System.system_time(:millisecond)

        {classified_state, max_sync_diff_ns} =
          classify_lock(sync_diffs, data.config.lock_threshold_ns)

        lock_state =
          apply_warmup(classified_state, data.cycle_count + 1, data.config.warmup_cycles)

        updated = %{
          data
          | fail_count: 0,
            lock_state: lock_state,
            max_sync_diff_ns: max_sync_diff_ns,
            last_sync_check_at_ms: now_ms
        }

        emit_monitor_telemetry(data, updated)
        updated

      {:error, reason} ->
        process_runtime_failure(data, %{diagnostics?: true}, reason)
    end
  end

  defp process_runtime_replies(data, _request, replies) do
    process_runtime_failure(data, %{diagnostics?: false}, {:unexpected_reply, length(replies)})
  end

  defp process_runtime_failure(data, %{diagnostics?: diagnostics?}, reason) do
    failures = data.fail_count + 1

    if failures >= 3 and (failures == 3 or rem(failures, 100) == 0) do
      Logger.warning("[DC] runtime tick failed: #{inspect(reason)} (#{failures} consecutive)")
    end

    updated =
      if diagnostics? and data.monitored_stations != [] do
        now_ms = System.system_time(:millisecond)
        next_state = if data.monitored_stations == [], do: :unavailable, else: :locking

        new_data = %{
          data
          | fail_count: failures,
            lock_state: next_state,
            last_sync_check_at_ms: now_ms
        }

        emit_monitor_telemetry(data, new_data)
        new_data
      else
        %{data | fail_count: failures}
      end

    updated
  end

  defp maybe_log_runtime_recovered(0), do: :ok

  defp maybe_log_runtime_recovered(fail_count) when fail_count > 0 do
    Logger.info("[DC] runtime recovered after #{fail_count} failure(s)")
  end

  defp emit_monitor_telemetry(old_data, new_data) do
    maybe_emit_sync_diff(new_data)
    maybe_emit_lock_change(old_data, new_data)
  end

  defp maybe_emit_sync_diff(%{
         max_sync_diff_ns: max_sync_diff_ns,
         ref_station: ref_station,
         monitored_stations: monitored_stations
       })
       when is_integer(max_sync_diff_ns) and is_integer(ref_station) do
    Telemetry.dc_sync_diff_observed(ref_station, max_sync_diff_ns, length(monitored_stations))
  end

  defp maybe_emit_sync_diff(_data), do: :ok

  defp maybe_emit_lock_change(%{lock_state: lock_state}, %{lock_state: lock_state}), do: :ok

  defp maybe_emit_lock_change(old_data, %{ref_station: ref_station} = new_data)
       when is_integer(ref_station) do
    Telemetry.dc_lock_changed(
      ref_station,
      old_data.lock_state,
      new_data.lock_state,
      new_data.max_sync_diff_ns
    )
  end

  defp maybe_emit_lock_change(_old_data, _new_data), do: :ok

  defp decode_sync_diffs([], [], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_sync_diffs(
         [_station | stations],
         [%{data: <<raw::32-little>>, wkc: 1} | results],
         acc
       ) do
    decode_sync_diffs(stations, results, [decode_abs_sync_diff(raw) | acc])
  end

  defp decode_sync_diffs([station | _stations], [%{wkc: wkc} | _results], _acc) do
    {:error, {:sync_diff_read_failed, station, {:unexpected_wkc, wkc}}}
  end

  defp decode_sync_diffs(stations, results, _acc) do
    {:error, {:sync_diff_unexpected_reply_count, length(results), length(stations)}}
  end

  defp runtime_status(data) do
    %Status{
      configured?: true,
      active?: true,
      cycle_ns: data.config.cycle_ns,
      reference_station: data.ref_station,
      lock_state: data.lock_state,
      max_sync_diff_ns: data.max_sync_diff_ns,
      last_sync_check_at_ms: data.last_sync_check_at_ms,
      monitor_failures: data.fail_count
    }
  end

  defp initial_lock_state([]), do: :unavailable
  defp initial_lock_state(_stations), do: :locking

  defp apply_warmup(:unavailable, _cycle_number, _warmup_cycles), do: :unavailable

  defp apply_warmup(lock_state, cycle_number, warmup_cycles)
       when is_integer(warmup_cycles) and warmup_cycles > 0 and cycle_number <= warmup_cycles do
    case lock_state do
      :locked -> :locking
      other -> other
    end
  end

  defp apply_warmup(lock_state, _cycle_number, _warmup_cycles), do: lock_state

  defp tick_interval_ms(cycle_ns) when is_integer(cycle_ns) and cycle_ns > 0 do
    ceil_div(cycle_ns, 1_000_000)
  end

  defp diagnostic_interval_cycles(cycle_ns) when is_integer(cycle_ns) and cycle_ns > 0 do
    max(1, ceil_div(@default_diagnostic_interval_ns, cycle_ns))
  end

  defp do_await_locked(server, deadline_ms) do
    case status(server) do
      %Status{lock_state: :locked} ->
        :ok

      %Status{lock_state: :unavailable} ->
        {:error, :dc_lock_unavailable}

      {:error, _reason} = err ->
        err

      %Status{} = status ->
        remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

        if remaining_ms <= 0 do
          {:error, :timeout}
        else
          Process.sleep(min(await_poll_interval_ms(status), remaining_ms))
          do_await_locked(server, deadline_ms)
        end
    end
  end

  defp await_poll_interval_ms(%Status{cycle_ns: cycle_ns})
       when is_integer(cycle_ns) and cycle_ns > 0 do
    cycle_ms = max(1, ceil_div(cycle_ns, 1_000_000))
    min(cycle_ms, 10)
  end

  defp await_poll_interval_ms(_status), do: 1

  defp tick_timeout_us(cycle_ns) when is_integer(cycle_ns) and cycle_ns > 0 do
    cycle_us = div(cycle_ns, 1_000)
    max(div(cycle_us * 9, 10), 200)
  end

  defp ceil_div(value, divisor) when is_integer(value) and is_integer(divisor) and divisor > 0 do
    div(value + divisor - 1, divisor)
  end

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
      {:ok, [%{wkc: 0} | _]} ->
        # wkc=0 on the ECAT receive-time register means this slave has no DC clock unit.
        # Return a non-DC snapshot so the caller can continue with other stations.
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
