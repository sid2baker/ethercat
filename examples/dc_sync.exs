#!/usr/bin/env elixir
# Distributed Clocks synchronization test.
#
# Tests the EtherCAT DC subsystem end-to-end:
#
#   1. Startup: bring bus to OP with DC enabled; show DC status.
#   2. Reference clock: identify which slave drives the DC master clock.
#   3. Lock convergence: poll max_sync_diff_ns until locked (or timeout).
#   4. Per-slave times: read dc_system_time and dc_system_time_diff per slave
#      via raw FPRD, compute inter-slave offsets relative to the reference.
#   5. Drift monitoring: collect max_sync_diff_ns samples while cycling;
#      report p50/p95/p99/max distribution and detect regressions.
#   6. Jitter comparison: loopback-gated cycle intervals with DC enabled vs
#      baseline domain stats — shows whether DC-driven cycles are tighter.
#
# If DC initialisation fails (hardware lacks DC support, or WKC=0 on DC regs)
# the script reports the status and runs a no-DC timing baseline instead so
# the run is still useful.
#
# Hardware:
#   position 0  EK1100 coupler
#   position 1  EL1809 16-ch digital input  (slave name :inputs)
#   position 2  EL2809 16-ch digital output (slave name :outputs)
#   position 3  EL3202 2-ch PT100           (slave name :rtd)
#
# Usage:
#   mix run examples/dc_sync.exs --interface enp0s31f6
#
# Optional flags:
#   --period-ms N        domain cycle period ms          (default 10)
#   --lock-timeout N     ms to wait for DC lock          (default 10_000)
#   --drift-samples N    sync_diff samples to collect    (default 200)
#   --jitter-samples N   half-cycles for jitter test     (default 500)
#   --lock-threshold N   ns sync_diff convergence gate   (default 1000)
#   --no-rtd             skip EL3202

# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------

defmodule DcSync.EL1809 do
  @behaviour EtherCAT.Slave.Driver
  @impl true
  def process_data_model(_config) do
    Enum.into(1..16, %{}, fn i -> {String.to_atom("ch#{i}"), 0x1A00 + i - 1} end)
  end
  @impl true
  def encode_signal(_pdo, _config, _), do: <<>>
  @impl true
  def decode_signal(_ch, _config, <<_::7, bit::1>>), do: bit
  def decode_signal(_pdo, _config, _), do: 0
end

defmodule DcSync.EL2809 do
  @behaviour EtherCAT.Slave.Driver
  @impl true
  def process_data_model(_config) do
    Enum.into(1..16, %{}, fn i -> {String.to_atom("ch#{i}"), 0x1600 + i - 1} end)
  end
  @impl true
  def encode_signal(_ch, _config, value), do: <<value::8>>
  @impl true
  def decode_signal(_pdo, _config, _), do: nil
end

defmodule DcSync.EL3202 do
  @behaviour EtherCAT.Slave.Driver
  @impl true
  def process_data_model(_config), do: %{channel1: 0x1A00, channel2: 0x1A01}
  @impl true
  def mailbox_config(_config) do
    [
      {:sdo_download, 0x8000, 0x19, <<8::16-little>>},
      {:sdo_download, 0x8010, 0x19, <<8::16-little>>}
    ]
  end
  @impl true
  def encode_signal(_pdo, _config, _value), do: <<>>
  @impl true
  def decode_signal(_pdo, _config, _), do: nil
end

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

{opts, _, _} =
  OptionParser.parse(System.argv(),
    switches: [
      interface: :string,
      period_ms: :integer,
      lock_timeout: :integer,
      drift_samples: :integer,
      jitter_samples: :integer,
      lock_threshold: :integer,
      no_rtd: :boolean
    ]
  )

interface       = opts[:interface] || raise "pass --interface, e.g. --interface enp0s31f6"
period_ms       = Keyword.get(opts, :period_ms, 10)
lock_timeout_ms = Keyword.get(opts, :lock_timeout, 10_000)
drift_samples   = Keyword.get(opts, :drift_samples, 200)
jitter_samples  = Keyword.get(opts, :jitter_samples, 500)
lock_threshold  = Keyword.get(opts, :lock_threshold, 1_000)
include_rtd     = not Keyword.get(opts, :no_rtd, false)

IO.puts("""
EtherCAT distributed clocks synchronization test
  interface       : #{interface}
  period          : #{period_ms} ms
  lock threshold  : #{lock_threshold} ns
  lock timeout    : #{lock_timeout_ms} ms
  drift samples   : #{drift_samples}
  jitter samples  : #{jitter_samples}
""")

# ---------------------------------------------------------------------------
# Phase 1: Start with DC enabled
# ---------------------------------------------------------------------------

IO.puts("── 1. Start with DC enabled ──────────────────────────────────────")

EtherCAT.stop()
Process.sleep(300)

rtd_slave = %EtherCAT.Slave.Config{
  name: :rtd,
  driver: DcSync.EL3202,
  process_data: {:all, :main}
}

:ok =
  EtherCAT.start(
    interface: interface,
    domains: [
      %EtherCAT.Domain.Config{
        id: :main,
        cycle_time_us: period_ms * 1_000,
        miss_threshold: 500
      }
    ],
    slaves:
      [
        %EtherCAT.Slave.Config{name: :coupler},
        %EtherCAT.Slave.Config{name: :inputs,  driver: DcSync.EL1809, process_data: {:all, :main}},
        %EtherCAT.Slave.Config{name: :outputs, driver: DcSync.EL2809, process_data: {:all, :main}}
      ] ++ if(include_rtd, do: [rtd_slave], else: []),
    dc: %EtherCAT.DC.Config{
      cycle_ns: period_ms * 1_000_000,
      await_lock?: false,
      lock_threshold_ns: lock_threshold,
      lock_timeout_ms: lock_timeout_ms
    }
  )

:ok = EtherCAT.await_running(15_000)

bus = EtherCAT.bus()

initial_dc = EtherCAT.dc_status()

IO.puts("""
  Master reached OP.
  DC configured? : #{initial_dc.configured?}
  DC active?     : #{initial_dc.active?}
  lock_state     : #{initial_dc.lock_state}
""")

dc_active = initial_dc.active?

# ---------------------------------------------------------------------------
# Phase 2: Reference clock
# ---------------------------------------------------------------------------

IO.puts("── 2. Reference clock ────────────────────────────────────────────")

case EtherCAT.reference_clock() do
  {:ok, ref} ->
    IO.puts("  reference slave : #{inspect(ref.name)}  station=0x#{Integer.to_string(ref.station, 16)}")

  {:error, reason} ->
    IO.puts("  no reference clock — #{inspect(reason)}")
    IO.puts("  (DC init may have failed; check hardware DC capability)")
end

# ---------------------------------------------------------------------------
# Phase 3: Lock convergence monitoring
# ---------------------------------------------------------------------------

IO.puts("\n── 3. Lock convergence ───────────────────────────────────────────")

convergence_data =
  if dc_active do
    IO.puts("  Polling max_sync_diff_ns until locked or #{lock_timeout_ms} ms elapsed...")
    IO.puts("  (threshold: #{lock_threshold} ns)\n")

    deadline = System.monotonic_time(:millisecond) + lock_timeout_ms
    t_start = System.monotonic_time(:millisecond)

    {final_state, samples} =
      Stream.repeatedly(fn -> :ok end)
      |> Enum.reduce_while({:locking, []}, fn _, {_last_state, acc} ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          {:halt, {:timeout, acc}}
        else
          status = EtherCAT.dc_status()

          sample =
            if is_integer(status.max_sync_diff_ns) do
              elapsed = now - t_start
              {elapsed, status.max_sync_diff_ns, status.lock_state}
            else
              nil
            end

          new_acc = if sample, do: [sample | acc], else: acc

          case status.lock_state do
            :locked ->
              {:halt, {:locked, new_acc}}

            :unavailable ->
              {:halt, {:unavailable, new_acc}}

            _ ->
              Process.sleep(min(period_ms * 2, 20))
              {:cont, {status.lock_state, new_acc}}
          end
        end
      end)

    samples_asc = Enum.reverse(samples)

    case final_state do
      :locked ->
        elapsed = System.monotonic_time(:millisecond) - t_start
        IO.puts("  ✓ Locked in #{elapsed} ms")

      :timeout ->
        IO.puts("  ✗ Did not lock within #{lock_timeout_ms} ms")

      :unavailable ->
        IO.puts("  ✗ DC lock unavailable (no monitorable DC-capable slaves)")
    end

    # Print convergence trace (first/last few + any lock transition)
    if samples_asc != [] do
      IO.puts("\n  Convergence trace (elapsed_ms, max_sync_diff_ns, state):")
      preview = Enum.take(samples_asc, 5) ++ Enum.take(samples_asc, -5)
      preview = Enum.uniq(preview)

      Enum.each(preview, fn {elapsed, diff_ns, state} ->
        IO.puts("    t=#{elapsed} ms  diff=#{diff_ns} ns  (#{state})")
      end)
    end

    %{final_state: final_state, samples: samples_asc}
  else
    IO.puts("  DC not active — skipping lock convergence.")
    IO.puts("  Possible causes:")
    IO.puts("    - Hardware does not support Distributed Clocks")
    IO.puts("    - DC receive-time latch returned WKC=0 (slave at that position lacks DC registers)")
    IO.puts("    - Topology snapshot read failed")
    %{final_state: :disabled, samples: []}
  end

# ---------------------------------------------------------------------------
# Phase 4: Per-slave DC register read
# ---------------------------------------------------------------------------

IO.puts("\n── 4. Per-slave DC registers (FPRD) ──────────────────────────────")

slave_list = EtherCAT.slaves()

hex = fn n -> "0x#{String.pad_leading(Integer.to_string(n, 16), 4, "0")}" end
ns_to_ms = fn ns -> Float.round(ns / 1_000_000.0, 3) end

ref_time =
  Enum.find_value(slave_list, fn {_name, station, _pid} ->
    case EtherCAT.Bus.transaction(
           bus,
           EtherCAT.Bus.Transaction.fprd(station, EtherCAT.Slave.Registers.dc_system_time())
         ) do
      {:ok, [%{data: <<t::64-little>>, wkc: 1}]} -> t
      _ -> nil
    end
  end)

if ref_time == nil do
  IO.puts("  (no slave responded to dc_system_time read — DC registers unavailable)")
else
  IO.puts("  Reference system time: #{ref_time} ns")
  IO.puts("")
  IO.puts("  #{String.pad_trailing("Slave", 12)} #{String.pad_trailing("Station", 10)} #{String.pad_trailing("SysTime (ns)", 22)} #{String.pad_trailing("Offset vs ref", 18)} SyncDiff")
  IO.puts("  " <> String.duplicate("-", 80))

  Enum.each(slave_list, fn {name, station, _pid} ->
    sys_time =
      case EtherCAT.Bus.transaction(
             bus,
             EtherCAT.Bus.Transaction.fprd(station, EtherCAT.Slave.Registers.dc_system_time())
           ) do
        {:ok, [%{data: <<t::64-little>>, wkc: 1}]} -> t
        _ -> nil
      end

    sync_diff =
      case EtherCAT.Bus.transaction(
             bus,
             EtherCAT.Bus.Transaction.fprd(station, EtherCAT.Slave.Registers.dc_system_time_diff())
           ) do
        {:ok, [%{data: <<raw::32-little>>, wkc: 1}]} ->
          <<_::1, abs_diff::31>> = <<raw::32>>
          abs_diff

        _ ->
          nil
      end

    sys_time_str = if sys_time, do: Integer.to_string(sys_time), else: "—"

    offset_str =
      if sys_time do
        offset = sys_time - ref_time
        "#{offset} ns (#{ns_to_ms.(abs(offset))} ms)"
      else
        "— (no DC)"
      end

    sync_diff_str = if sync_diff, do: "#{sync_diff} ns", else: "— (no DC)"

    IO.puts(
      "  #{String.pad_trailing(inspect(name), 12)} #{String.pad_trailing(hex.(station), 10)} #{String.pad_trailing(sys_time_str, 22)} #{String.pad_trailing(offset_str, 18)} #{sync_diff_str}"
    )
  end)
end

# ---------------------------------------------------------------------------
# Phase 5: Drift monitoring (if DC active)
# ---------------------------------------------------------------------------

IO.puts("\n── 5. Drift monitoring ───────────────────────────────────────────")

drift_stats =
  if dc_active do
    IO.puts("  Collecting #{drift_samples} max_sync_diff_ns samples (#{period_ms * 2} ms between each)...")

    samples =
      Enum.reduce_while(1..drift_samples, [], fn _, acc ->
        Process.sleep(period_ms * 2)
        status = EtherCAT.dc_status()

        if is_integer(status.max_sync_diff_ns) do
          {:cont, [status.max_sync_diff_ns | acc]}
        else
          {:halt, acc}
        end
      end)
      |> Enum.reverse()

    if samples == [] do
      IO.puts("  No sync_diff data collected (DC diagnostic cycle may not have run yet)")
      nil
    else
      sorted = Enum.sort(samples)
      n = length(sorted)
      mean = Enum.sum(sorted) / n

      percentile = fn list, pct ->
        idx = min(round(pct / 100.0 * (n - 1)), n - 1)
        Enum.at(list, idx)
      end

      IO.puts("""
        #{n} samples:
          min    : #{hd(sorted)} ns
          p50    : #{percentile.(sorted, 50)} ns
          p95    : #{percentile.(sorted, 95)} ns
          p99    : #{percentile.(sorted, 99)} ns
          max    : #{List.last(sorted)} ns
          mean   : #{Float.round(mean, 1)} ns
          locked : #{EtherCAT.dc_status().lock_state}
      """)

      %{n: n, min: hd(sorted), p50: percentile.(sorted, 50), p95: percentile.(sorted, 95),
        p99: percentile.(sorted, 99), max: List.last(sorted), mean: mean}
    end
  else
    IO.puts("  DC not active — skipping drift monitoring.")
    nil
  end

# ---------------------------------------------------------------------------
# Phase 6: Jitter comparison (loopback self-clocking)
# ---------------------------------------------------------------------------

IO.puts("\n── 6. Loopback jitter (DC#{if dc_active, do: " enabled", else: " disabled"}) ───────────────────────────────────")

EtherCAT.subscribe(:inputs, :ch1, self())

# Stabilise: write 0, sleep, flush
EtherCAT.write_output(:outputs, :ch1, 0)
Process.sleep(period_ms * 5)

# Flush stale notifications
Stream.repeatedly(fn ->
  receive do
    {:ethercat, :signal, :inputs, :ch1, _} -> true
  after
    0 -> false
  end
end)
|> Stream.take_while(& &1)
|> Stream.run()

IO.puts("  Priming loopback ch1=1...")

EtherCAT.write_output(:outputs, :ch1, 1)

primed =
  receive do
    {:ethercat, :signal, :inputs, :ch1, 1} -> :ok
  after
    5_000 -> :timeout
  end

jitter_result =
  if primed == :ok do
    IO.puts("  Collecting #{jitter_samples} half-cycles...")

    {:ok, stats_before} = EtherCAT.Domain.stats(:main)
    t_collect_start = System.monotonic_time(:microsecond)

    {intervals, _} =
      Enum.map_reduce(0..(jitter_samples - 1), System.monotonic_time(:microsecond), fn i, prev_t ->
        target = rem(i, 2)
        EtherCAT.write_output(:outputs, :ch1, target)

        receive do
          {:ethercat, :signal, :inputs, :ch1, ^target} -> :ok
        after
          5_000 -> raise "loopback timeout — check EL2809 ch1 → EL1809 ch1 wire"
        end

        now = System.monotonic_time(:microsecond)
        {now - prev_t, now}
      end)

    {:ok, stats_after} = EtherCAT.Domain.stats(:main)

    wall_us = System.monotonic_time(:microsecond) - t_collect_start
    miss_delta = stats_after.total_miss_count - stats_before.total_miss_count
    cycle_delta = stats_after.cycle_count - stats_before.cycle_count

    round_trip_us = period_ms * 1_000 * 2
    jitter = Enum.map(intervals, fn iv -> abs(iv - round_trip_us) end)
    sorted = Enum.sort(jitter)
    n = length(sorted)

    percentile = fn list, pct ->
      idx = min(round(pct / 100.0 * (n - 1)), n - 1)
      Enum.at(list, idx)
    end

    mean_j = Enum.sum(sorted) / n

    p99_j = percentile.(sorted, 99)

    verdict =
      cond do
        p99_j <= round_trip_us * 0.05 -> "EXCELLENT (p99 ≤ 5% of round-trip)"
        p99_j <= round_trip_us * 0.15 -> "GOOD (p99 ≤ 15% of round-trip)"
        p99_j <= round_trip_us * 0.30 -> "FAIR (p99 ≤ 30% of round-trip)"
        true -> "POOR — consider RT kernel, CPU isolation, or process priority"
      end

    IO.puts("""
      #{n} intervals (round-trip = #{round_trip_us} µs = 2 × #{period_ms} ms):
        p50    : #{percentile.(sorted, 50)} µs
        p95    : #{percentile.(sorted, 95)} µs
        p99    : #{p99_j} µs
        max    : #{List.last(sorted)} µs
        mean   : #{Float.round(mean_j, 1)} µs
      Domain:
        cycles : #{cycle_delta}
        misses : #{miss_delta}
        wall   : #{Float.round(wall_us / 1_000.0, 1)} ms
      Verdict: #{verdict}
    """)

    %{p99_us: p99_j, verdict: verdict, miss_delta: miss_delta}
  else
    IO.puts("  ✗ Loopback prime timeout — skipping jitter test (check EL2809 ch1 → EL1809 ch1 wire)")
    nil
  end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

IO.puts("""
── Summary ───────────────────────────────────────────────────────────
  DC active          : #{dc_active}
  DC lock state      : #{EtherCAT.dc_status().lock_state}
  Convergence result : #{convergence_data.final_state}
""")

if drift_stats do
  IO.puts("  Sync diff (steady-state):")
  IO.puts("    p50 = #{drift_stats.p50} ns   p99 = #{drift_stats.p99} ns   max = #{drift_stats.max} ns")
end

if jitter_result do
  IO.puts("  Loopback jitter p99 : #{jitter_result.p99_us} µs  (#{jitter_result.verdict})")
  if jitter_result.miss_delta > 0 do
    IO.puts("  ⚠ #{jitter_result.miss_delta} domain miss(es) during jitter test")
  end
end

if not dc_active do
  IO.puts("""
  Note: DC initialisation failed on this hardware.
  EK1100/EL18xx/EL28xx slaves may not implement Distributed Clocks.
  For DC support, use a coupler and I/O modules with DC capability
  (EK1100 + slaves that respond to register 0x0910).
  """)
end

IO.puts("──────────────────────────────────────────────────────────────────")

# Cleanup
EtherCAT.write_output(:outputs, :ch1, 0)
Process.sleep(period_ms * 3)
EtherCAT.stop()
