#!/usr/bin/env elixir
# Multi-domain multi-rate test + split-SM validation.
#
# This example deliberately splits one physical SyncManager-backed PDO area
# across multiple domains:
#
#   :fast (1ms)
#     EL2809 :ch1 output
#     EL1809 :ch1 input
#
#   :slow (10ms)
#     EL2809 :ch2 output
#     EL1809 :ch2 input
#
#   :rtd (50ms, optional)
#     EL3202 RTD inputs
#
# The EL1809 and EL2809 each expose one process-data SyncManager, so putting
# `:ch1` in `:fast` and `:ch2` in `:slow` exercises split `{domain, SM}`
# attachments on both the input and output side.
#
# What it measures:
#
#   Phase 1 — per-domain cycle health
#     actual cycle count vs expected, miss count, cycle execution time
#     p50/p95/p99/max via telemetry events
#
#   Phase 2 — split-SM loopback latency
#     measure one loopback in the 1ms `:fast` domain and one in the 10ms
#     `:slow` domain while both domains share the same digital I/O SMs.
#
#   Phase 3 — sub-millisecond feasibility
#     measure actual LRW frame round-trip in the 1ms `:fast` domain, report
#     headroom,
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
#   --cross-samples N   loopback latency samples              (default 50)
#   --no-rtd            skip EL3202 (runs 2 domains only)

# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------

defmodule MultiDomain.EL1809 do
  @behaviour EtherCAT.Slave.Driver
  @impl true
  def process_data_model(_config) do
    Enum.map(1..16, fn i -> {String.to_atom("ch#{i}"), 0x1A00 + i - 1} end)
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
    Enum.map(1..16, fn i -> {String.to_atom("ch#{i}"), 0x1600 + i - 1} end)
  end

  @impl true
  def encode_signal(_ch, _config, value), do: <<value::8>>
  @impl true
  def decode_signal(_pdo, _config, _), do: nil
end

defmodule MultiDomain.EL3202 do
  @behaviour EtherCAT.Slave.Driver
  @impl true
  def process_data_model(_config), do: [channel1: 0x1A00, channel2: 0x1A01]
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

defmodule MultiDomain.Telemetry do
  def handle(
        [:ethercat, :domain, :cycle, :done],
        %{duration_us: duration_us},
        %{domain: domain},
        _cfg
      ) do
    :ets.insert(:md_durations, {domain, duration_us})
  end

  def handle([:ethercat, :domain, :cycle, :missed], _measurements, %{domain: domain}, _cfg) do
    :ets.update_counter(:md_misses, domain, {2, 1}, {domain, 0})
  end
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

interface = opts[:interface] || raise "pass --interface, e.g. --interface enp0s31f6"
run_s = Keyword.get(opts, :run_s, 10)
cross_samples = Keyword.get(opts, :cross_samples, 50)
include_rtd = not Keyword.get(opts, :no_rtd, false)

fast_period_ms = 1
slow_period_ms = 10
rtd_period_ms = 50

IO.puts("""
EtherCAT multi-domain multi-rate test + split-SM validation
  interface  : #{interface}
  domains    : :fast #{fast_period_ms}ms  :slow #{slow_period_ms}ms#{if include_rtd, do: "  :rtd #{rtd_period_ms}ms", else: "  (no rtd)"}
  run        : #{run_s} s
  split SMs  : EL2809 ch1/ch2 and EL1809 ch1/ch2 are split across :fast/:slow
""")

# ---------------------------------------------------------------------------
# Phase 1: Start
# ---------------------------------------------------------------------------

IO.puts("── 1. Start ──────────────────────────────────────────────────────")

EtherCAT.stop()
Process.sleep(300)

domain_configs =
  [
    %EtherCAT.Domain.Config{
      id: :fast,
      cycle_time_us: fast_period_ms * 1_000,
      miss_threshold: 500
    },
    %EtherCAT.Domain.Config{
      id: :slow,
      cycle_time_us: slow_period_ms * 1_000,
      miss_threshold: 500
    }
  ] ++
    if include_rtd,
      do: [
        %EtherCAT.Domain.Config{
          id: :rtd,
          cycle_time_us: rtd_period_ms * 1_000,
          miss_threshold: 500
        }
      ],
      else: []

rtd_slave = %EtherCAT.Slave.Config{
  name: :rtd,
  driver: MultiDomain.EL3202,
  process_data: {:all, :rtd}
}

:ok =
  EtherCAT.start(
    interface: interface,
    domains: domain_configs,
    slaves:
      [
        %EtherCAT.Slave.Config{name: :coupler},
        %EtherCAT.Slave.Config{
          name: :inputs,
          driver: MultiDomain.EL1809,
          process_data: [ch1: :fast, ch2: :slow]
        },
        %EtherCAT.Slave.Config{
          name: :outputs,
          driver: MultiDomain.EL2809,
          process_data: [ch1: :fast, ch2: :slow]
        }
      ] ++ if(include_rtd, do: [rtd_slave], else: [])
  )

:ok = EtherCAT.await_running(15_000)
IO.puts("  Bus reached OP.")

Enum.each([:fast, :slow] ++ if(include_rtd, do: [:rtd], else: []), fn domain_id ->
  {:ok, info} = EtherCAT.domain_info(domain_id)
  IO.puts("  #{inspect(domain_id)} domain logical_base=#{info.logical_base}")
end)

Enum.each([:inputs, :outputs], fn slave_name ->
  {:ok, info} = EtherCAT.slave_info(slave_name)

  IO.puts(
    "  #{inspect(slave_name)}: #{info.used_fmmus}/#{info.available_fmmus} FMMUs used " <>
      "(#{length(info.attachments)} attachment(s))"
  )

  Enum.each(info.attachments, fn attachment ->
    IO.puts(
      "    SM#{attachment.sm_index} #{attachment.direction} -> #{inspect(attachment.domain)} " <>
        "logical=#{attachment.logical_address} size=#{attachment.sm_size} signals=#{inspect(attachment.signals)}"
    )
  end)
end)

# ---------------------------------------------------------------------------
# Telemetry accumulator (ETS bag per domain)
# ---------------------------------------------------------------------------

:ets.new(:md_durations, [:named_table, :public, :bag])
:ets.new(:md_misses, [:named_table, :public, :set])

tracked_ids = [:fast, :slow] ++ if(include_rtd, do: [:rtd], else: [])
Enum.each(tracked_ids, fn id -> :ets.insert(:md_misses, {id, 0}) end)

handler_id = "multi-domain-#{System.unique_integer([:positive, :monotonic])}"

:telemetry.attach_many(
  handler_id,
  [[:ethercat, :domain, :cycle, :done], [:ethercat, :domain, :cycle, :missed]],
  &MultiDomain.Telemetry.handle/4,
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

configured =
  [
    {:fast, fast_period_ms},
    {:slow, slow_period_ms}
  ] ++ if(include_rtd, do: [{:rtd, rtd_period_ms}], else: [])

domain_stats =
  Enum.map(configured, fn {id, period_ms} ->
    durations =
      :ets.lookup(:md_durations, id)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sort()

    [{^id, miss_count}] = :ets.lookup(:md_misses, id)

    actual_cycles = length(durations)
    expected_cycles = div(actual_ms, period_ms)

    miss_rate_pct =
      if actual_cycles > 0, do: Float.round(miss_count / actual_cycles * 100, 3), else: 0.0

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
# Phase 2: Split-SM loopback latency
# ---------------------------------------------------------------------------

IO.puts("── 3. Split-SM loopback latency ─────────────────────────────────")
IO.puts("  each pair shares the same slave SyncManagers but runs in a different domain\n")

EtherCAT.subscribe(:inputs, :ch1, self())
EtherCAT.subscribe(:inputs, :ch2, self())

flush_input = fn flush_input, signal_name ->
  receive do
    {:ethercat, :signal, :inputs, ^signal_name, _value} ->
      flush_input.(flush_input, signal_name)
  after
    0 -> :ok
  end
end

measure_loopback = fn label, signal_name, period_ms ->
  IO.puts(
    "  #{inspect(signal_name)} in :#{label} (#{period_ms}ms): " <>
      "EL2809 #{signal_name} -> EL1809 #{signal_name}"
  )

  IO.puts(
    "    expected worst-case: #{period_ms * 2}ms " <>
      "(one output cycle + one input cycle)"
  )

  EtherCAT.write_output(:outputs, signal_name, 0)
  Process.sleep(period_ms * 5)
  flush_input.(flush_input, signal_name)
  EtherCAT.write_output(:outputs, signal_name, 1)

  primed =
    receive do
      {:ethercat, :signal, :inputs, ^signal_name, 1} -> :ok
    after
      3_000 -> :timeout
    end

  result =
    if primed == :ok do
      {latencies_rev, _} =
        Enum.reduce(1..cross_samples, {[], :primed}, fn idx, {acc, _prev} ->
          target = rem(idx, 2)
          t0 = System.monotonic_time(:microsecond)
          EtherCAT.write_output(:outputs, signal_name, target)

          latency_us =
            receive do
              {:ethercat, :signal, :inputs, ^signal_name, ^target} ->
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
        IO.puts("    ✗ No latency samples collected (loopback wire missing?)\n")
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
        """)

        %{
          label: label,
          signal_name: signal_name,
          p50_us: pct.(50),
          p99_us: pct.(99),
          max_us: List.last(latencies),
          mean_us: mean_us
        }
      end
    else
      IO.puts(
        "    ✗ Loopback prime timeout — check EL2809 #{signal_name} -> EL1809 #{signal_name}\n"
      )

      nil
    end

  EtherCAT.write_output(:outputs, signal_name, 0)
  result
end

latency_stats =
  [
    {:fast, :ch1, fast_period_ms},
    {:slow, :ch2, slow_period_ms}
  ]
  |> Enum.map(fn {label, signal_name, period_ms} ->
    measure_loopback.(label, signal_name, period_ms)
  end)
  |> Enum.filter(& &1)

# ---------------------------------------------------------------------------
# Phase 3: Sub-ms feasibility from :fast domain (1ms)
# ---------------------------------------------------------------------------

IO.puts("── 4. Sub-ms feasibility (:fast @ 1ms) ───────────────────────────")

fast_stats = Enum.find(domain_stats, &(&1.id == :fast))

if fast_stats && fast_stats.p99_us != nil do
  p99_us = fast_stats.p99_us
  mean_us = fast_stats.mean_us || 0.0

  util_mean_pct = Float.round(mean_us / (fast_period_ms * 1_000) * 100, 1)
  util_p99_pct = Float.round(p99_us / (fast_period_ms * 1_000) * 100, 1)

  # Theoretical minimum: next whole-millisecond above p99 * 1.5 safety margin
  theoretical_floor_us = ceil(p99_us * 1.5 / 1_000) * 1_000

  IO.puts("""
  LRW frame duration at 1ms cycle (:fast, #{fast_stats.actual_cycles} cycles):
    mean  : #{mean_us} µs    (#{util_mean_pct}% of 1000µs period)
    p99   : #{p99_us} µs    (#{util_p99_pct}% of 1000µs period)
    max   : #{fast_stats.max_us} µs

  High-level API floor: cycle_time_us >= 1_000 µs (whole-millisecond scheduler contract)
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
  IO.puts("  No :fast timing data — skipping feasibility analysis.")
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

total_cycles = Enum.sum(Enum.map(domain_stats, & &1.actual_cycles))
total_misses = Enum.sum(Enum.map(domain_stats, & &1.miss_count))

IO.puts("""

── Summary ───────────────────────────────────────────────────────────
  Domains          : #{length(domain_stats)}  (digital SMs split across :fast / :slow)
  Total LRW frames : #{total_cycles}  in #{actual_ms} ms
  Total misses     : #{total_misses}
""")

Enum.each(latency_stats, fn stats ->
  IO.puts(
    "  #{inspect(stats.signal_name)} in :#{stats.label}: " <>
      "p50=#{stats.p50_us}µs  p99=#{stats.p99_us}µs  max=#{stats.max_us}µs"
  )
end)

IO.puts("──────────────────────────────────────────────────────────────────")

EtherCAT.stop()
