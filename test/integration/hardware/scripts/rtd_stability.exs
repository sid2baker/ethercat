#!/usr/bin/env elixir
# EL3202 long-duration RTD stability analysis.
#
# ## Hardware Requirements
#
# Required slaves:
#   - EK1100 coupler
#   - EL3202 two-channel PT100 RTD terminal at slave name `:rtd`
#
# Optional slaves:
#   - EL1809 and EL2809 are started only to preserve the maintained bench
#     topology; the script does not exercise their process data
#
# Required capabilities:
#   - CoE mailbox access so EL3202 startup configuration succeeds
#   - stable PDO updates for `channel1` and `channel2` during the run
#
# Accumulates per-channel statistics using Welford's online algorithm
# (numerically stable running mean + variance without storing all samples).
#
# What it measures:
#   - mean, stddev, min, max resistance per channel
#   - toggle-bit continuity: consecutive cycles where the toggle bit did NOT
#     change flag a stale-data condition (slave stopped updating)
#   - outlier rate: samples > N·stddev from running mean
#   - overrange / underrange / error event counts
#   - data rate: effective sample rate derived from toggle-bit transitions
#
# Output: periodic report every --report-s seconds, plus a final summary.
#
# Hardware:
#   position 0  EK1100 coupler
#   position 1  EL1809 16-ch digital input  (started but not read)
#   position 2  EL2809 16-ch digital output (started but not written)
#   position 3  EL3202 2-ch PT100           (slave name :rtd)
#
# Usage:
#   MIX_ENV=test mix run test/integration/hardware/scripts/rtd_stability.exs --interface enp0s31f6
#
# Optional flags:
#   --period-ms N    EtherCAT cycle period in ms      (default 10)
#   --duration-s N   total run duration in seconds    (default 60)
#   --report-s N     periodic report interval seconds (default 10)
#   --sigma N        outlier threshold in stddevs      (default 4)

# ---------------------------------------------------------------------------
# Welford accumulator (pure functions, immutable state)
# ---------------------------------------------------------------------------

defmodule Welford do
  defstruct n: 0, mean: 0.0, m2: 0.0, min: nil, max: nil

  def new, do: %__MODULE__{}

  def update(%__MODULE__{n: n, mean: mean, m2: m2, min: mn, max: mx}, x) do
    x = x / 1.0
    n1 = n + 1
    delta = x - mean
    new_mean = mean + delta / n1
    delta2 = x - new_mean

    %__MODULE__{
      n: n1,
      mean: new_mean,
      m2: m2 + delta * delta2,
      min: if(mn == nil or x < mn, do: x, else: mn),
      max: if(mx == nil or x > mx, do: x, else: mx)
    }
  end

  def variance(%__MODULE__{n: n, m2: m2}) when n > 1, do: m2 / (n - 1)
  def variance(_), do: 0.0

  def stddev(acc), do: :math.sqrt(variance(acc))
end

alias EtherCAT.IntegrationSupport.Hardware

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

{opts, _, _} =
  OptionParser.parse(System.argv(),
    switches: [
      interface: :string,
      period_ms: :integer,
      duration_s: :integer,
      report_s: :integer,
      sigma: :integer
    ]
  )

interface = opts[:interface] || raise "pass --interface, e.g. --interface enp0s31f6"
period_ms = Keyword.get(opts, :period_ms, 10)
duration_s = Keyword.get(opts, :duration_s, 60)
report_s = Keyword.get(opts, :report_s, 10)
sigma = Keyword.get(opts, :sigma, 4)

IO.puts("""
EL3202 RTD long-duration stability analysis
  interface  : #{interface}
  period     : #{period_ms} ms
  duration   : #{duration_s} s
  report     : every #{report_s} s
  outlier    : > #{sigma}σ
""")

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

EtherCAT.stop()
Process.sleep(300)

:ok =
  EtherCAT.start(
    interface: interface,
    domains: [Hardware.main_domain(cycle_time_us: period_ms * 1_000, miss_threshold: 500)],
    slaves: Hardware.full_ring()
  )

IO.puts("Waiting for bus to reach OP...")
:ok = EtherCAT.await_running(15_000)

EtherCAT.subscribe(:rtd, :channel1, self())
EtherCAT.subscribe(:rtd, :channel2, self())

# ---------------------------------------------------------------------------
# Collection loop
# ---------------------------------------------------------------------------

# Per-channel mutable state using a map of Welford accumulators + counters
initial_state = fn ->
  %{
    acc: Welford.new(),
    errors: 0,
    overranges: 0,
    underranges: 0,
    invalids: 0,
    outliers: 0,
    # times toggle bit didn't change across consecutive samples
    stale_runs: 0,
    last_toggle: nil,
    stale_streak: 0,
    # counts actual data refreshes from slave
    toggle_transitions: 0
  }
end

state = %{
  channel1: initial_state.(),
  channel2: initial_state.()
}

deadline = System.monotonic_time(:millisecond) + duration_s * 1_000
next_report_at = System.monotonic_time(:millisecond) + report_s * 1_000

fmt_f = fn f -> :erlang.float_to_binary(f, decimals: 3) end
fmt_ohms = fn v -> "#{fmt_f.(v)} Ω" end

print_report = fn state, label ->
  IO.puts("\n── #{label} " <> String.duplicate("─", max(0, 60 - String.length(label))))

  for ch <- [:channel1, :channel2] do
    s = state[ch]

    if s.acc.n == 0 do
      IO.puts("  #{ch}: no data yet")
    else
      sd = Welford.stddev(s.acc)

      _toggle_rate_hz =
        if s.acc.n > 1,
          do: Float.round(s.toggle_transitions / (duration_s * 1.0), 1),
          else: 0.0

      IO.puts("""
        #{ch}  (#{s.acc.n} samples):
          mean   : #{fmt_ohms.(s.acc.mean)}
          stddev : #{fmt_ohms.(sd)}
          min    : #{fmt_ohms.(s.acc.min)}
          max    : #{fmt_ohms.(s.acc.max)}
          range  : #{fmt_ohms.(s.acc.max - s.acc.min)}
          errors : overrange=#{s.overranges}  underrange=#{s.underranges}  error=#{s.errors}  invalid=#{s.invalids}
          outliers (>#{sigma}σ) : #{s.outliers}
          stale runs : #{s.stale_runs}   toggle transitions : #{s.toggle_transitions}
      """)
    end
  end
end

{final_state, _} =
  Stream.repeatedly(fn -> :ok end)
  |> Enum.reduce_while({state, next_report_at}, fn _, {st, nra} ->
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:halt, {st, nra}}
    else
      msg =
        receive do
          {:ethercat, :signal, :rtd, ch, reading} when ch in [:channel1, :channel2] ->
            {:reading, ch, reading}
        after
          period_ms * 20 -> :timeout
        end

      new_st =
        case msg do
          {:reading, _ch, nil} ->
            st

          {:reading, ch, reading} ->
            s = st[ch]
            acc1 = Welford.update(s.acc, reading.ohms)

            # Outlier check (only after we have enough samples for a valid stddev)
            is_outlier =
              acc1.n > 20 and Welford.stddev(acc1) > 0.0 and
                abs(reading.ohms - acc1.mean) > sigma * Welford.stddev(acc1)

            # Toggle bit continuity
            {stale_streak, stale_runs, toggle_transitions} =
              cond do
                s.last_toggle == nil ->
                  {0, s.stale_runs, s.toggle_transitions}

                reading.toggle != s.last_toggle ->
                  # Toggle flipped — slave produced a fresh sample
                  {0, s.stale_runs, s.toggle_transitions + 1}

                true ->
                  # Same toggle value — either slave hasn't updated or bus cycle
                  # is faster than RTD conversion rate.
                  new_streak = s.stale_streak + 1

                  # Only count as a "stale run" if we've seen 3+ consecutive unchanged toggles
                  stale =
                    if new_streak >= 3 and s.stale_streak < 3,
                      do: s.stale_runs + 1,
                      else: s.stale_runs

                  {new_streak, stale, s.toggle_transitions}
              end

            %{
              st
              | ch => %{
                  s
                  | acc: acc1,
                    errors: s.errors + if(reading.error, do: 1, else: 0),
                    overranges: s.overranges + if(reading.overrange, do: 1, else: 0),
                    underranges: s.underranges + if(reading.underrange, do: 1, else: 0),
                    invalids: s.invalids + if(reading.invalid, do: 1, else: 0),
                    outliers: s.outliers + if(is_outlier, do: 1, else: 0),
                    stale_runs: stale_runs,
                    stale_streak: stale_streak,
                    toggle_transitions: toggle_transitions,
                    last_toggle: reading.toggle
                }
            }

          :timeout ->
            IO.puts("  ⚠ tick timeout — no signal for #{period_ms * 20} ms")
            st
        end

      # Periodic report
      now2 = System.monotonic_time(:millisecond)
      elapsed_s = div(duration_s * 1_000 - (deadline - now2), 1_000) |> max(0)

      {new_st2, new_nra} =
        if now2 >= nra do
          print_report.(new_st, "t=#{elapsed_s}s / #{duration_s}s")
          {new_st, now2 + report_s * 1_000}
        else
          {new_st, nra}
        end

      {:cont, {new_st2, new_nra}}
    end
  end)

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------

print_report.(final_state, "Final summary")

# Health verdict per channel
IO.puts("\nHealth verdict:")

for ch <- [:channel1, :channel2] do
  s = final_state[ch]

  issues =
    []
    |> then(fn a -> if s.errors > 0, do: ["#{s.errors} error events" | a], else: a end)
    |> then(fn a -> if s.overranges > 0, do: ["#{s.overranges} overrange" | a], else: a end)
    |> then(fn a -> if s.underranges > 0, do: ["#{s.underranges} underrange" | a], else: a end)
    |> then(fn a -> if s.invalids > 0, do: ["#{s.invalids} invalid" | a], else: a end)
    |> then(fn a -> if s.outliers > 0, do: ["#{s.outliers} outlier(s)" | a], else: a end)
    |> then(fn a -> if s.stale_runs > 0, do: ["#{s.stale_runs} stale run(s)" | a], else: a end)

  if issues == [] do
    IO.puts("  #{ch}: ✓ clean")
  else
    IO.puts("  #{ch}: ✗ #{Enum.join(issues, ", ")}")
  end
end

EtherCAT.stop()
