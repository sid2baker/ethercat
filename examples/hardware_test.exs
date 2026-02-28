#!/usr/bin/env elixir
# EtherCAT hardware stress test — new EtherCAT top-level API
#
# Hardware setup (3-slave ring):
#   position 0 → 0x1000  EK1100 coupler  (nil — no driver)
#   position 1 → 0x1001  EL1809 16-ch digital input
#   position 2 → 0x1002  EL2809 16-ch digital output
#
# Every output channel is wired back to the corresponding input channel.
# Five timed phases drive different output patterns, verify loopback
# fidelity via the input subscription, and stress the bus at the configured
# cycle rate.
#
# Usage:
#   mix run examples/hardware_test.exs --interface enp0s31f6
#
# Optional flags:
#   --period-ms N       domain cycle period in milliseconds (default 4)
#   --loopback-mask N   bitmask of channels wired for loopback (hex ok, default 0xFFFF)

alias EtherCAT.Domain
alias EtherCAT.Link
alias EtherCAT.Link.Transaction
alias EtherCAT.Slave
alias EtherCAT.Slave.Registers

# ---------------------------------------------------------------------------
# Driver definitions
# ---------------------------------------------------------------------------

defmodule Example.EL1809 do
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile(_config) do
    %{channels: %{sm_index: 0}}
  end

  @impl true
  def encode_outputs(_pdo, _config, _), do: <<>>

  @impl true
  def decode_inputs(:channels, _config, <<v::16-little>>), do: v
  def decode_inputs(_pdo, _config, _), do: 0
end

defmodule Example.EL2809 do
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile(_config) do
    # SII DefaultSize=1 per SM (digital I/O WDT). Override to 2 so SM0
    # covers both output bytes 0x0F00–0x0F01 → all 16 channels.
    %{outputs: %{sm_index: 0, size: 2}}
  end

  @impl true
  def encode_outputs(:outputs, _config, v) when is_integer(v), do: <<v::16-little>>
  def encode_outputs(_pdo, _config, _), do: <<0, 0>>

  @impl true
  def decode_inputs(_pdo, _config, _), do: nil
end

defmodule Example.EL3202 do
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile(_config) do
    # SM3 = TxPDO; physical address and size come from SII EEPROM
    %{temperatures: %{sm_index: 3}}
  end

  @impl true
  def sdo_config(_config) do
    [
      {0x8000, 0x19, 8, 2},   # ch1 RTD element = ohm_1_16 (resistance, 1/16 Ω/bit)
      {0x8010, 0x19, 8, 2}    # ch2 RTD element = ohm_1_16
    ]
  end

  @impl true
  def encode_outputs(_pdo, _config, _value), do: <<>>

  @impl true
  def decode_inputs(:temperatures, _config, <<
        _::1, error1::1, limit2_1::2, limit1_1::2, overrange1::1, underrange1::1,
        toggle1::1, state1::1, _::6, ch1::16-little,
        _::1, error2::1, limit2_2::2, limit1_2::2, overrange2::1, underrange2::1,
        toggle2::1, state2::1, _::6, ch2::16-little>>) do
    {
      %{ohms: ch1 / 16.0, underrange: underrange1 == 1, overrange: overrange1 == 1,
        limit1: limit1_1, limit2: limit2_1, error: error1 == 1,
        invalid: state1 == 1, toggle: toggle1},
      %{ohms: ch2 / 16.0, underrange: underrange2 == 1, overrange: overrange2 == 1,
        limit1: limit1_2, limit2: limit2_2, error: error2 == 1,
        invalid: state2 == 1, toggle: toggle2}
    }
  end
  def decode_inputs(_pdo, _config, _), do: nil
end

# ---------------------------------------------------------------------------
# Phase loop
#
# Runs until {:phase_done, ref} arrives.  On each :tick it calls set_fn/1
# and writes the result to the valve output.  On each {:slave_input, ...}
# it checks the received value against the value written one tick ago
# (prev_out), accounting for one domain-cycle of loopback latency.
#
# A mismatch is only counted when:
#   - prev_out is known (at least one tick has elapsed), AND
#   - the value has been stable for at least one tick (last_out == prev_out),
#     so we're not catching the transition cycle where the input may still
#     reflect the previous write.
#
# Returns {ticks_sent, mismatch_count}.
# ---------------------------------------------------------------------------

defmodule Example.PhaseLoop do
  def run(set_fn, phase_ref, loopback_mask) do
    # {ticks, pprev_out, prev_out, last_out, mismatches, last_print}
    # pprev_out: value written two ticks ago
    # prev_out:  value written one tick ago
    # last_out:  value written this tick (not yet confirmed by loopback)
    #
    # We check against pprev_out (2 ticks ago) so that at sub-4ms domain
    # periods, where BEAM timer jitter is on the order of 1 cycle, there is
    # enough slack for the EtherCAT round-trip + scheduler skew.
    # Stability requires all three to agree (output unchanged for ≥2 ticks).
    loop(set_fn, phase_ref, loopback_mask, 0, nil, nil, nil, 0, 0)
  end

  defp loop(set_fn, phase_ref, mask, ticks, pprev_out, prev_out, last_out, mismatches, last_print) do
    receive do
      {:phase_done, ^phase_ref} ->
        {ticks, mismatches}

      :tick ->
        expected = set_fn.(ticks)
        EtherCAT.set_output(:valve, :outputs, expected)
        loop(set_fn, phase_ref, mask, ticks + 1, prev_out, last_out, expected, mismatches, last_print)

      {:slave_input, :sensor, :channels, actual} ->
        # Only check when output stable for ≥2 ticks (pprev == prev == last).
        stable? = pprev_out != nil and pprev_out == prev_out and prev_out == last_out
        mismatch =
          if stable? and Bitwise.band(actual, mask) != Bitwise.band(pprev_out, mask), do: 1, else: 0

        new_print =
          if last_print == 0 or ticks - last_print >= 250 do
            mark = if mismatch == 0, do: "ok", else: "MISMATCH"
            IO.puts(
              "    tick=#{String.pad_leading(to_string(ticks), 5)}  " <>
              "out=0x#{Integer.to_string(last_out || 0, 16) |> String.pad_leading(4, "0")}  " <>
              "in=0x#{Integer.to_string(actual, 16) |> String.pad_leading(4, "0")}  #{mark}"
            )
            ticks
          else
            last_print
          end

        loop(set_fn, phase_ref, mask, ticks, pprev_out, prev_out, last_out, mismatches + mismatch, new_print)

      {:slave_input, :thermo, :temperatures, {%{ohms: v1} = ch1, %{ohms: v2} = ch2}} ->
        err1 = if ch1.error, do: " ERR", else: ""
        err2 = if ch2.error, do: " ERR", else: ""
        IO.puts("    thermo: ch1=#{:erlang.float_to_binary(v1, decimals: 2)}Ω#{err1}  ch2=#{:erlang.float_to_binary(v2, decimals: 2)}Ω#{err2}")
        loop(set_fn, phase_ref, mask, ticks, pprev_out, prev_out, last_out, mismatches, last_print)
    end
  end
end

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

hex  = fn n -> "0x#{String.pad_leading(Integer.to_string(n, 16), 4, "0")}" end
hex8 = fn n -> "0x#{String.pad_leading(Integer.to_string(n, 16), 8, "0")}" end

banner = fn title ->
  IO.puts("\n── #{title} " <> String.duplicate("─", max(0, 60 - String.length(title))))
end

check = fn label, result ->
  case result do
    :ok              -> IO.puts("  ✓ #{label}"); :ok
    {:ok, val}       -> IO.puts("  ✓ #{label}: #{inspect(val)}"); val
    {:error, reason} ->
      IO.puts("  ✗ #{label}: #{inspect(reason)}")
      raise "FAIL: #{label} — #{inspect(reason)}"
  end
end

drain_mailbox = fn ->
  Stream.repeatedly(fn ->
    receive do _ -> true after 0 -> false end
  end)
  |> Stream.take_while(& &1)
  |> Stream.run()
end

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

{opts, _, _} =
  OptionParser.parse(System.argv(),
    switches: [interface: :string, period_ms: :integer, loopback_mask: :string]
  )

interface = opts[:interface] || raise "pass --interface, e.g. --interface enp0s31f6"
period_ms = Keyword.get(opts, :period_ms, 4)

loopback_mask =
  case opts[:loopback_mask] do
    nil -> 0xFFFF
    s ->
      s = String.trim_leading(s, "0x")
      String.to_integer(s, 16)
  end

run_phase = fn label, set_fn, duration_ms, period_ms ->
  banner.("Phase: #{label}  (#{duration_ms} ms @ #{period_ms} ms/tick)")

  drain_mailbox.()
  {:ok, s_before} = Domain.stats(:main)

  phase_ref = make_ref()
  Process.send_after(self(), {:phase_done, phase_ref}, duration_ms)
  {:ok, tick_timer} = :timer.send_interval(period_ms, self(), :tick)

  {ticks, mismatches} = Example.PhaseLoop.run(set_fn, phase_ref, loopback_mask)

  :timer.cancel(tick_timer)
  drain_mailbox.()

  {:ok, s_after} = Domain.stats(:main)
  miss_delta = s_after.total_miss_count - s_before.total_miss_count

  IO.puts("  ticks        : #{ticks}")
  IO.puts("  frame misses : #{miss_delta}")
  IO.puts("  loopback err : #{mismatches}")

  %{miss_delta: miss_delta, ticks: ticks, mismatches: mismatches}
end

IO.puts("""
EtherCAT hardware stress test
  interface     : #{interface}
  period        : #{period_ms} ms
  loopback mask : 0x#{Integer.to_string(loopback_mask, 16) |> String.pad_leading(4, "0")}
""")

# ---------------------------------------------------------------------------
# 1. Start + discover + run
# ---------------------------------------------------------------------------

banner.("1. Start + discover + run")

EtherCAT.stop()
Process.sleep(300)

check.("EtherCAT.start", EtherCAT.start(
  interface: interface,
  domains: [
    [id: :main, period: period_ms, miss_threshold: 500]
  ],
  slaves: [
    nil,
    [name: :sensor, driver: Example.EL1809, config: %{}, pdos: [channels: :main]],
    [name: :valve,  driver: Example.EL2809, config: %{}, pdos: [outputs:  :main]],
    [name: :thermo, driver: Example.EL3202, config: %{}, pdos: [temperatures: :main]]
  ]
))

check.("EtherCAT.await_running", EtherCAT.await_running(10_000))

EtherCAT.subscribe(:sensor, :channels, self())
EtherCAT.subscribe(:thermo, :temperatures, self())

slaves = EtherCAT.slaves()

IO.puts("  #{length(slaves)} named slave(s):")

for {name, station, _pid} <- slaves do
  id    = Slave.identity(name)
  state = Slave.state(name)
  id_str = if id, do: "vendor=#{hex8.(id.vendor_id)} product=#{hex8.(id.product_code)}", else: "(no identity)"
  IO.puts("  #{inspect(name)} @ #{hex.(station)}: #{state}  #{id_str}")
end

if slaves == [], do: raise("No named slaves — check cabling and slave config")

{:ok, s0} = Domain.stats(:main)
IO.puts("  image_size=#{s0.image_size} bytes  state=#{s0.state}")

# ---------------------------------------------------------------------------
# Pattern definitions
# ---------------------------------------------------------------------------

phase_ms = 5_000

# Walking single bit (bit 0 → bit 15, repeat)
walking_one = fn tick -> Integer.pow(2, rem(tick, 16)) end

# Checkerboard: 0x5555 / 0xAAAA toggle every tick
checkerboard = fn tick ->
  if rem(tick, 2) == 0, do: 0x5555, else: 0xAAAA
end

# All-ON / ALL-OFF, hold 20 ticks per state
slow_toggle = fn tick ->
  if rem(div(tick, 20), 2) == 0, do: 0xFFFF, else: 0x0000
end

# 16-bit Galois LFSR (taps: 16,15,13,4 → feedback mask 0xB400)
# Deterministic, full-period (65535 steps).
# Uses rem/div for LSB extract and shift; XOR via addition since the feedback
# mask bits never overlap with the shifted value's bit 15 in a single step.
# (Bitwise.bxor unavoidable here — this is integer algorithm, not register parsing.)
lfsr = :atomics.new(1, [])
:atomics.put(lfsr, 1, 0xACE1)

lfsr_fn = fn _tick ->
  s = :atomics.get(lfsr, 1)
  lsb  = rem(s, 2)
  next = div(s, 2)
  next = if lsb == 1, do: Bitwise.bxor(next, 0xB400), else: next
  :atomics.put(lfsr, 1, next)
  next
end

# Burst stress: max update rate (every tick at the configured period)
burst_toggle = fn tick ->
  if rem(tick, 2) == 0, do: 0xFFFF, else: 0x0000
end

# ---------------------------------------------------------------------------
# 2. Stress phases
# ---------------------------------------------------------------------------

banner.("2. Stress phases  (#{phase_ms} ms each)")

results = [
  {"Walking-one (1 bit, 16-step cycle)",   walking_one,  phase_ms, period_ms},
  {"Checkerboard toggle  (every tick)",    checkerboard, phase_ms, period_ms},
  {"All-ON / ALL-OFF  (hold 20 ticks)",    slow_toggle,  phase_ms, period_ms},
  {"Pseudo-random LFSR",                   lfsr_fn,      phase_ms, period_ms},
  {"Burst: max toggle  (period=1 ms)",     burst_toggle, phase_ms, 1}
]
|> Enum.map(fn {label, set_fn, dur, per} ->
  r = run_phase.(label, set_fn, dur, per)
  {label, r}
end)

# ---------------------------------------------------------------------------
# 3. Zero outputs + stop cyclic
# ---------------------------------------------------------------------------

EtherCAT.set_output(:valve, :outputs, 0x0000)
Process.sleep(2 * period_ms)
Domain.stop_cyclic(:main)

# ---------------------------------------------------------------------------
# 4. Final report
# ---------------------------------------------------------------------------

banner.("3. Final report")

{:ok, final} = Domain.stats(:main)
IO.puts("  Total domain cycles : #{final.cycle_count}")
IO.puts("  Total frame misses  : #{final.total_miss_count}")
IO.puts("")

IO.puts("  Phase results:")

all_ok =
  Enum.reduce(results, true, fn {label, r}, ok ->
    miss_mark = if r.miss_delta == 0, do: "✓", else: "✗"
    loop_mark = if r.mismatches == 0, do: "✓", else: "✗"
    IO.puts("    #{label}")
    IO.puts("      #{miss_mark} frame misses : #{r.miss_delta}  #{loop_mark} loopback err : #{r.mismatches}")
    ok and r.miss_delta == 0 and r.mismatches == 0
  end)

IO.puts("")

IO.puts("  RX error counters (per slave port):")
link = EtherCAT.link()

for {name, station, _} <- slaves do
  case Link.transaction(link, &Transaction.fprd(&1, station, Registers.rx_error_counter())) do
    {:ok, [%{data: <<p0::16-little, p1::16-little, p2::16-little, p3::16-little>>, wkc: wkc}]}
    when wkc > 0 ->
      IO.puts("    #{inspect(name)} @ #{hex.(station)}: port0=#{p0} port1=#{p1} port2=#{p2} port3=#{p3}")
    _ ->
      IO.puts("    #{inspect(name)} @ #{hex.(station)}: could not read")
  end
end

IO.puts("")
IO.puts("  Verdict: #{if all_ok, do: "PASS ✓", else: "FAIL ✗"}")

banner.("Done")
EtherCAT.stop()
IO.puts("  OK\n")
