#!/usr/bin/env elixir
# Domain cycle jitter histogram — self-clocking loopback method.
#
# Measures the actual inter-cycle interval using a hardware feedback loop:
#
#   1. Write :outputs ch1 = 1
#   2. Wait for {:ethercat, :signal, :inputs, :ch1, 1}  ← one domain cycle later
#   3. Write :outputs ch1 = 0
#   4. Wait for {:ethercat, :signal, :inputs, :ch1, 0}  ← one domain cycle later
#   5. Repeat — each notification represents exactly one domain cycle passing
#
# Because the loopback wire gates each toggle through the hardware bus, the
# inter-notification interval is the true domain cycle period, not just
# the Erlang scheduler interval.  Jitter = |actual - configured_period|.
#
# Outputs:
#   - p50 / p95 / p99 / p99.9 / max jitter
#   - histogram in configurable µs buckets
#   - domain miss count during the test run
#
# Hardware:
#   EL2809 ch1 → EL1809 ch1 (loopback wire required)
#
# Usage:
#   mix run examples/cycle_jitter.exs --interface enp0s31f6
#
# Optional flags:
#   --period-ms N    domain cycle period ms     (default 10)
#   --samples N      number of half-cycles      (default 2000)
#   --bucket-us N    histogram bucket width µs  (default 100)

# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------

defmodule CycleJitter.EL1809 do
  @behaviour EtherCAT.Slave.Driver
  @impl true
  def process_data_model(_config), do: Enum.into(1..16, %{}, fn i -> {:"ch#{i}", 0x1A00 + i - 1} end)
  @impl true
  def encode_signal(_pdo, _config, _), do: <<>>
  @impl true
  def decode_signal(_ch, _config, <<_::7, bit::1>>), do: bit
  def decode_signal(_pdo, _config, _), do: 0
end

defmodule CycleJitter.EL2809 do
  @behaviour EtherCAT.Slave.Driver
  @impl true
  def process_data_model(_config), do: Enum.into(1..16, %{}, fn i -> {:"ch#{i}", 0x1600 + i - 1} end)
  @impl true
  def encode_signal(_ch, _config, value), do: <<value::8>>
  @impl true
  def decode_signal(_pdo, _config, _), do: nil
end

defmodule CycleJitter.EL3202 do
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
# Self-clocking loopback collector
#
# Alternates ch1 between 0 and 1, recording the timestamp of each
# input notification.  The interval between consecutive timestamps is one
# domain cycle.  Returns a list of intervals in microseconds.
# ---------------------------------------------------------------------------

defmodule CycleJitter.Collector do
  @timeout_ms 5_000

  def collect(n, period_ms) do
    # Drive ch1 to a known 0 state and wait for it to propagate through hardware.
    # Without the sleep, a subsequent write(1) may overwrite the 0 in ETS before
    # any domain cycle fires, leaving the input unchanged → no notification.
    EtherCAT.write_output(:outputs, :ch1, 0)
    Process.sleep(period_ms * 4)
    flush_ch1()

    # Arm: write 1 and wait for the first rising-edge confirmation
    EtherCAT.write_output(:outputs, :ch1, 1)
    wait_for(:ch1, 1)

    # Now collect n transitions.  Each wait_for call is one bus cycle.
    # Start at i=0 so target=0 first — priming left ch1=1, so the first write(0)
    # guarantees a real transition and a notification.
    {intervals, _} =
      Enum.map_reduce(0..(n - 1), System.monotonic_time(:microsecond), fn i, prev_t ->
        target = rem(i, 2)                           # 0, 1, 0, 1 ...
        EtherCAT.write_output(:outputs, :ch1, target)
        wait_for(:ch1, target)
        now = System.monotonic_time(:microsecond)
        {now - prev_t, now}
      end)

    # Leave ch1 = 0
    EtherCAT.write_output(:outputs, :ch1, 0)
    intervals
  end

  defp wait_for(ch, value) do
    receive do
      {:ethercat, :signal, :inputs, ^ch, ^value} -> :ok
    after
      @timeout_ms -> raise "loopback timeout waiting for #{ch}=#{value} — check wiring"
    end
  end

  defp flush_ch1 do
    receive do
      {:ethercat, :signal, :inputs, :ch1, _} -> flush_ch1()
    after
      0 -> :ok
    end
  end
end

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

{opts, _, _} =
  OptionParser.parse(System.argv(),
    switches: [interface: :string, period_ms: :integer, samples: :integer, bucket_us: :integer]
  )

interface = opts[:interface] || raise "pass --interface, e.g. --interface enp0s31f6"
period_ms = Keyword.get(opts, :period_ms, 10)
samples   = Keyword.get(opts, :samples, 2_000)
bucket_us = Keyword.get(opts, :bucket_us, 100)
period_us = period_ms * 1_000

IO.puts("""
EtherCAT domain cycle jitter (self-clocking loopback)
  interface  : #{interface}
  period     : #{period_ms} ms (#{period_us} µs)
  samples    : #{samples} half-cycles
  bucket     : #{bucket_us} µs
  method     : output toggle → loopback → input notification
""")

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

EtherCAT.stop()
Process.sleep(300)

:ok =
  EtherCAT.start(
    interface: interface,
    domains: [
      %EtherCAT.Domain.Config{id: :main, cycle_time_us: period_us, miss_threshold: 500}
    ],
    slaves: [
      %EtherCAT.Slave.Config{name: :coupler},
      %EtherCAT.Slave.Config{name: :inputs,  driver: CycleJitter.EL1809, process_data: {:all, :main}},
      %EtherCAT.Slave.Config{name: :outputs, driver: CycleJitter.EL2809, process_data: {:all, :main}},
      %EtherCAT.Slave.Config{name: :rtd,     driver: CycleJitter.EL3202, process_data: {:all, :main}}
    ]
  )

IO.puts("Waiting for bus to reach OP...")
:ok = EtherCAT.await_running(15_000)

EtherCAT.subscribe(:inputs, :ch1, self())

# Warm-up: discard first 50 cycles to let the bus stabilise.
# Write 0 first and sleep to ensure hardware sees 0 before we start toggling.
IO.puts("Warming up (50 cycles)...")
EtherCAT.write_output(:outputs, :ch1, 0)
Process.sleep(period_ms * 4)

# Flush any notifications that arrived during the sleep
Stream.repeatedly(fn ->
  receive do
    {:ethercat, :signal, :inputs, :ch1, _} -> true
  after
    0 -> false
  end
end)
|> Stream.take_while(& &1)
|> Stream.run()

Enum.each(1..50, fn i ->
  target = rem(i, 2)
  EtherCAT.write_output(:outputs, :ch1, target)

  receive do
    {:ethercat, :signal, :inputs, :ch1, ^target} -> :ok
  after
    2_000 -> raise "warm-up timeout — check EL2809 ch1 → EL1809 ch1 loopback wire"
  end
end)

# ---------------------------------------------------------------------------
# Collect
# ---------------------------------------------------------------------------

IO.puts("Collecting #{samples} samples...")
{:ok, stats_before} = EtherCAT.Domain.stats(:main)

intervals = CycleJitter.Collector.collect(samples, period_ms)

{:ok, stats_after} = EtherCAT.Domain.stats(:main)
miss_delta = stats_after.total_miss_count - stats_before.total_miss_count

# ---------------------------------------------------------------------------
# Jitter = |interval - round_trip_us|
#
# Each measured interval spans TWO domain cycles: the output write is picked
# up by cycle N, the looped-back input arrives in cycle N+1.  The natural
# round-trip is therefore 2×period.  Jitter is deviation from that reference.
# ---------------------------------------------------------------------------

round_trip_us = period_us * 2
jitter = Enum.map(intervals, fn iv -> abs(iv - round_trip_us) end)
sorted  = Enum.sort(jitter)
sorted_intervals = Enum.sort(intervals)
n = length(sorted)

percentile = fn list, pct ->
  idx = min(round(pct / 100.0 * (n - 1)), n - 1)
  Enum.at(list, idx)
end

mean_iv = Enum.sum(intervals) / n
mean_j  = Enum.sum(jitter) / n

var_j = Enum.reduce(jitter, 0.0, fn x, acc -> acc + (x - mean_j) * (x - mean_j) end) / n
stddev_j = :math.sqrt(var_j)

IO.puts("""

Interval statistics (each = output→loopback round-trip ≈ 2 cycles):
  min    : #{percentile.(sorted_intervals, 0)} µs
  p50    : #{percentile.(sorted_intervals, 50)} µs
  p99    : #{percentile.(sorted_intervals, 99)} µs
  max    : #{List.last(sorted_intervals)} µs
  mean   : #{Float.round(mean_iv, 1)} µs  (expected: #{round_trip_us} µs)

Jitter |interval − #{round_trip_us} µs|:
  min    : #{hd(sorted)} µs
  p50    : #{percentile.(sorted, 50)} µs
  p95    : #{percentile.(sorted, 95)} µs
  p99    : #{percentile.(sorted, 99)} µs
  p99.9  : #{percentile.(sorted, 99.9)} µs
  max    : #{List.last(sorted)} µs
  mean   : #{Float.round(mean_j, 1)} µs
  stddev : #{Float.round(stddev_j, 1)} µs

Domain health:
  frame misses during test : #{miss_delta}
  cycles during test       : #{stats_after.cycle_count - stats_before.cycle_count}
""")

# ---------------------------------------------------------------------------
# Histogram
# ---------------------------------------------------------------------------

max_j = List.last(sorted)
num_buckets = div(max_j, bucket_us) + 1

hist =
  Enum.reduce(sorted, %{}, fn v, acc ->
    b = div(v, bucket_us)
    Map.update(acc, b, 1, &(&1 + 1))
  end)

bar_scale = max(div(n, 40), 1)

IO.puts("Jitter histogram (#{bucket_us} µs buckets, █ = #{bar_scale} samples):")
IO.puts(String.duplicate("-", 72))

Enum.each(0..(num_buckets - 1), fn b ->
  count = Map.get(hist, b, 0)

  if count > 0 do
    bar   = String.duplicate("█", max(div(count, bar_scale), 1))
    label = "#{b * bucket_us}–#{(b + 1) * bucket_us - 1} µs" |> String.pad_leading(14)
    pct   = Float.round(count / n * 100, 1)
    IO.puts("  #{label} │#{bar} #{count} (#{pct}%)")
  end
end)

IO.puts(String.duplicate("-", 72))

# Verdict
p99_j = percentile.(sorted, 99)
verdict =
  cond do
    p99_j <= round_trip_us * 0.05 -> "EXCELLENT — p99 ≤ 5% of round-trip"
    p99_j <= round_trip_us * 0.15 -> "GOOD — p99 ≤ 15% of round-trip"
    p99_j <= round_trip_us * 0.30 -> "FAIR — p99 ≤ 30% of round-trip"
    true                          -> "POOR — consider RT kernel, CPU isolation, or process priority"
  end

miss_note = if miss_delta > 0, do: "  ⚠ #{miss_delta} frame miss(es) during test\n", else: ""
IO.puts("\n#{miss_note}  Verdict: #{verdict}\n")

EtherCAT.stop()
