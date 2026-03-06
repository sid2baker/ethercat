#!/usr/bin/env elixir
# Multi-domain multi-rate test + sub-millisecond feasibility probe.
#
# Each EtherCAT slave's SyncManager maps to exactly one domain — you cannot
# split one SM across multiple domains.  With the 4-slave test ring we can
# run up to 3 meaningful domains, one per I/O slave:
#
#   :outputs (EL2809, 1ms)  — fast control loop, high-rate output writes
#   :inputs  (EL1809, 10ms) — slower feedback loop, relaxed input sampling
#   :rtd     (EL3202, 50ms) — slow thermal loop, analogue RTD conversion rate
#
# What it measures:
#
#   Phase 1 — per-domain cycle health
#     actual cycle count vs expected, miss count, cycle execution time
#     p50/p95/p99/max via telemetry events
#
#   Phase 2 — cross-domain loopback latency
#     write EL2809 ch1 in the 1ms :outputs domain, wait for EL1809 ch1
#     to update in the 10ms :inputs domain.
#     Expected: up to (outputs_period + inputs_period) = 11ms worst-case.
#     Compare vs a same-domain loopback baseline.
#
#   Phase 3 — sub-millisecond feasibility
#     measure actual LRW frame round-trip at 1ms, report headroom,
#     and state the API floor (cycle_time_us >= 1_000).
#
# Hardware:
#   position 0  EK1100 coupler
#   position 1  EL1809 16-ch digital input  (slave name :inputs)
#   position 2  EL2809 16-ch digital output (slave name :outputs)
#   position 3  EL3202 2-ch PT100           (slave name :rtd, optional)
#
# Usage:
#   mix run examples/multi_domain.exs --interface enp0s31f6
#
# Optional flags:
#   --run-s N           multi-domain run duration in seconds  (default 10)
#   --cross-samples N   cross-domain latency samples          (default 50)
#   --no-rtd            skip EL3202 (runs 2 domains only)

# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------

defmodule MultiDomain.EL1809 do
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

defmodule MultiDomain.EL2809 do
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

defmodule MultiDomain.EL3202 do
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
      run_s: :integer,
      cross_samples: :integer,
      no_rtd: :boolean
    ]
  )

interface     = opts[:interface] || raise "pass --interface, e.g. --interface enp0s31f6"
run_s         = Keyword.get(opts, :run_s, 10)
cross_samples = Keyword.get(opts, :cross_samples, 50)
include_rtd   = not Keyword.get(opts, :no_rtd, false)

outputs_period_ms = 1
inputs_period_ms  = 10
rtd_period_ms     = 50

IO.puts("""
EtherCAT multi-domain multi-rate test + sub-ms feasibility probe
  interface  : #{interface}
  domains    : :outputs #{outputs_period_ms}ms  :inputs #{inputs_period_ms}ms#{if include_rtd, do: "  :rtd #{rtd_period_ms}ms", else: "  (no rtd)"}
  run        : #{run_s} s
  Note: SM constraint — one SyncManager per domain; max domains = slaves with PDOs
""")

# ---------------------------------------------------------------------------
# Phase 1: Start
# ---------------------------------------------------------------------------

IO.puts("── 1. Start ──────────────────────────────────────────────────────")

EtherCAT.stop()
Process.sleep(300)

# EL2809 = 16 output bits = 2 bytes image; EL1809 = 2 bytes; EL3202 = 8 bytes.
# All domains must have non-overlapping logical address ranges or their FMMUs
# will both respond to the other domain's LRW frame (unexpected WKC → all-miss).
domain_configs = [
  %EtherCAT.Domain.Config{id: :outputs, cycle_time_us: outputs_period_ms * 1_000, miss_threshold: 500, logical_base: 0},
  %EtherCAT.Domain.Config{id: :inputs,  cycle_time_us: inputs_period_ms  * 1_000, miss_threshold: 500, logical_base: 8}
] ++ if include_rtd, do: [%EtherCAT.Domain.Config{id: :rtd, cycle_time_us: rtd_period_ms * 1_000, miss_threshold: 500, logical_base: 16}], else: []

rtd_slave = %EtherCAT.Slave.Config{name: :rtd, driver: MultiDomain.EL3202, process_data: {:all, :rtd}}

:ok =
  EtherCAT.start(
    interface: interface,
    domains: domain_configs,
    slaves:
      [
        %EtherCAT.Slave.Config{name: :coupler},
        %EtherCAT.Slave.Config{name: :inputs,  driver: MultiDomain.EL1809, process_data: {:all, :inputs}},
        %EtherCAT.Slave.Config{name: :outputs, driver: MultiDomain.EL2809, process_data: {:all, :outputs}}
      ] ++ if(include_rtd, do: [rtd_slave], else: [])
  )

:ok = EtherCAT.await_running(15_000)
IO.puts("  Bus reached OP.")

# ---------------------------------------------------------------------------
# Telemetry accumulator (ETS bag per domain)
# ---------------------------------------------------------------------------

:ets.new(:md_durations, [:named_table, :public, :bag])
:ets.new(:md_misses,    [:named_table, :public, :set])

tracked_ids = [:outputs, :inputs] ++ if(include_rtd, do: [:rtd], else: [])
Enum.each(tracked_ids, fn id -> :ets.insert(:md_misses, {id, 0}) end)

handler_id = "multi-domain-#{System.unique_integer([:positive, :monotonic])}"

:telemetry.attach_many(
  handler_id,
  [[:ethercat, :domain, :cycle, :done], [:ethercat, :domain, :cycle, :missed]],
  fn
    [:ethercat, :domain, :cycle, :done], %{duration_us: dur}, %{domain: domain}, _cfg ->
      :ets.insert(:md_durations, {domain, dur})
    [:ethercat, :domain, :cycle, :missed], _m, %{domain: domain}, _cfg ->
      :ets.update_counter(:md_misses, domain, {2, 1}, {domain, 0})
  end,
  nil
)

# ---------------------------------------------------------------------------
# Run for run_s seconds
# ---------------------------------------------------------------------------

IO.puts("  Collecting #{run_s} s of domain telemetry...")
t_start = System.monotonic_time(:millisecond)
Process.sleep(run_s * 1_000)
t_end = System.monotonic_time(:millisecond)
:telemetry.detach(handler_id)
actual_ms = t_end - t_start

# ---------------------------------------------------------------------------
# Per-domain report
# ---------------------------------------------------------------------------

IO.puts("\n── 2. Per-domain health (#{actual_ms} ms run) ──────────────────────────")

configured = [
  {:outputs, outputs_period_ms},
  {:inputs,  inputs_period_ms}
] ++ if(include_rtd, do: [{:rtd, rtd_period_ms}], else: [])

domain_stats =
  Enum.map(configured, fn {id, period_ms} ->
    durations =
      :ets.lookup(:md_durations, id)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sort()

    [{^id, miss_count}] = :ets.lookup(:md_misses, id)

    actual_cycles   = length(durations)
    expected_cycles = div(actual_ms, period_ms)
    miss_rate_pct   = if actual_cycles > 0, do: Float.round(miss_count / actual_cycles * 100, 3), else: 0.0

    {p50, p95, p99, max_dur, mean_dur} =
      if durations != [] do
        n = length(durations)
        pct = fn p -> Enum.at(durations, min(round(p / 100.0 * (n - 1)), n - 1)) end
        mean = Float.round(Enum.sum(durations) / n, 1)
        {pct.(50), pct.(95), pct.(99), List.last(durations), mean}
      else
        {nil, nil, nil, nil, nil}
      end

    na = fn v -> if v, do: "#{v}", else: "—" end

    IO.puts("""
      #{inspect(id)} (#{period_ms}ms):
        cycles  : #{actual_cycles} actual / #{expected_cycles} expected
        misses  : #{miss_count}  (#{miss_rate_pct}%)
        duration: mean=#{na.(mean_dur)}µs  p50=#{na.(p50)}µs  p95=#{na.(p95)}µs  p99=#{na.(p99)}µs  max=#{na.(max_dur)}µs
    """)

    %{
      id: id,
      period_ms: period_ms,
      actual_cycles: actual_cycles,
      expected_cycles: expected_cycles,
      miss_count: miss_count,
      p50_us: p50,
      p99_us: p99,
      max_us: max_dur,
      mean_us: mean_dur
    }
  end)

# ---------------------------------------------------------------------------
# Phase 2: Cross-domain loopback latency
# ---------------------------------------------------------------------------

IO.puts("── 3. Cross-domain loopback latency ──────────────────────────────")
IO.puts("  write EL2809 ch1 (:outputs #{outputs_period_ms}ms) → read EL1809 ch1 (:inputs #{inputs_period_ms}ms)")
IO.puts("  expected worst-case: #{outputs_period_ms + inputs_period_ms}ms (output cycle + input cycle)\n")

EtherCAT.subscribe(:inputs, :ch1, self())

# Prime to 0, flush
EtherCAT.write_output(:outputs, :ch1, 0)
Process.sleep(inputs_period_ms * 5)

Stream.repeatedly(fn ->
  receive do
    {:ethercat, :signal, :inputs, :ch1, _} -> true
  after
    0 -> false
  end
end)
|> Stream.take_while(& &1)
|> Stream.run()

# Arm to 1
EtherCAT.write_output(:outputs, :ch1, 1)

primed =
  receive do
    {:ethercat, :signal, :inputs, :ch1, 1} -> :ok
  after
    3_000 -> :timeout
  end

cross_latencies =
  if primed == :ok do
    IO.puts("  Collecting #{cross_samples} cross-domain latency samples...")

    {latencies_rev, _} =
      Enum.reduce(1..cross_samples, {[], :primed}, fn idx, {acc, _prev} ->
        target = rem(idx, 2)
        t0 = System.monotonic_time(:microsecond)
        EtherCAT.write_output(:outputs, :ch1, target)

        latency_us =
          receive do
            {:ethercat, :signal, :inputs, :ch1, ^target} ->
              System.monotonic_time(:microsecond) - t0
          after
            3_000 -> nil
          end

        {[latency_us | acc], target}
      end)

    latencies =
      latencies_rev
      |> Enum.reverse()
      |> Enum.filter(&is_integer/1)
      |> Enum.sort()

    if latencies == [] do
      IO.puts("  ✗ No cross-domain samples collected (loopback wire missing?)")
      nil
    else
      n = length(latencies)
      mean_us = Float.round(Enum.sum(latencies) / n, 1)
      pct = fn p -> Enum.at(latencies, min(round(p / 100.0 * (n - 1)), n - 1)) end

      IO.puts("""
        #{n} samples:
          min  : #{hd(latencies)} µs
          p50  : #{pct.(50)} µs
          p95  : #{pct.(95)} µs
          p99  : #{pct.(99)} µs
          max  : #{List.last(latencies)} µs
          mean : #{mean_us} µs
          expected worst-case : #{(outputs_period_ms + inputs_period_ms) * 1_000} µs
      """)

      %{p50_us: pct.(50), p99_us: pct.(99), max_us: List.last(latencies), mean_us: mean_us}
    end
  else
    IO.puts("  ✗ Loopback prime timeout — check EL2809 ch1 → EL1809 ch1 wire")
    nil
  end

# Zero outputs
EtherCAT.write_output(:outputs, :ch1, 0)

# ---------------------------------------------------------------------------
# Phase 3: Sub-ms feasibility from :outputs domain (1ms)
# ---------------------------------------------------------------------------

IO.puts("── 4. Sub-ms feasibility (:outputs @ 1ms) ────────────────────────")

outputs_stats = Enum.find(domain_stats, &(&1.id == :outputs))

if outputs_stats && outputs_stats.p99_us != nil do
  p99_us   = outputs_stats.p99_us
  mean_us  = outputs_stats.mean_us || 0.0

  util_mean_pct = Float.round(mean_us / (outputs_period_ms * 1_000) * 100, 1)
  util_p99_pct  = Float.round(p99_us / (outputs_period_ms * 1_000) * 100, 1)

  # Theoretical minimum: next whole-millisecond above p99 * 1.5 safety margin
  theoretical_floor_us = ceil(p99_us * 1.5 / 1_000) * 1_000

  IO.puts("""
  LRW frame duration at 1ms cycle (:outputs, #{outputs_stats.actual_cycles} cycles):
    mean  : #{mean_us} µs    (#{util_mean_pct}% of 1000µs period)
    p99   : #{p99_us} µs    (#{util_p99_pct}% of 1000µs period)
    max   : #{outputs_stats.max_us} µs

  API floor: cycle_time_us >= 1_000 µs (whole-millisecond constraint in master/config.ex)
  """)

  cond do
    p99_us < 300 ->
      IO.puts("  ✓ p99 frame = #{p99_us}µs — bus is at #{util_p99_pct}% utilisation at 1ms.")
      IO.puts("    The hardware could support sub-ms cycles if the API floor were lifted.")
      IO.puts("    Theoretical safe floor (p99 × 1.5): #{theoretical_floor_us} µs")
      IO.puts("    Candidate cycle times: #{p99_us * 2} µs, #{p99_us * 3} µs, 500 µs")

    p99_us < 600 ->
      IO.puts("  ~ p99 frame = #{p99_us}µs (#{util_p99_pct}% at 1ms) — marginal headroom.")
      IO.puts("    Sub-ms would be risky without RT kernel / CPU isolation.")
      IO.puts("    Theoretical safe floor: #{theoretical_floor_us} µs")

    true ->
      IO.puts("  ✗ p99 frame = #{p99_us}µs (#{util_p99_pct}% at 1ms) — insufficient headroom.")
      IO.puts("    Sub-ms cycles would cause excessive misses on this system.")
  end
else
  IO.puts("  No :outputs timing data — skipping feasibility analysis.")
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

total_cycles = Enum.sum(Enum.map(domain_stats, & &1.actual_cycles))
total_misses = Enum.sum(Enum.map(domain_stats, & &1.miss_count))

IO.puts("""

── Summary ───────────────────────────────────────────────────────────
  Domains          : #{length(domain_stats)}  (SM constraint: 1 SM → 1 domain)
  Total LRW frames : #{total_cycles}  in #{actual_ms} ms
  Total misses     : #{total_misses}
""")

if cross_latencies do
  IO.puts(
    "  Cross-domain latency (:outputs 1ms → :inputs 10ms):" <>
    " p50=#{cross_latencies.p50_us}µs  p99=#{cross_latencies.p99_us}µs  max=#{cross_latencies.max_us}µs"
  )
end

IO.puts("──────────────────────────────────────────────────────────────────")

EtherCAT.stop()
