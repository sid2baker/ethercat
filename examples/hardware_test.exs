#!/usr/bin/env elixir
# EtherCAT hardware stress test — named-slave + Domain API
#
# Hardware setup (3-slave ring):
#   position 0 → 0x1000  EK1100 coupler  (nil — no driver)
#   position 1 → 0x1001  EL1809 16-ch digital input
#   position 2 → 0x1002  EL2809 16-ch digital output
#
# Every output channel is wired back to the corresponding input channel.
# Four timed phases drive different output patterns, verify loopback
# fidelity via the input subscription, and stress the bus at the configured
# cycle rate.
#
# Usage:
#   mix run examples/hardware_test.exs --interface enp0s31f6
#
# Optional flags:
#   --period-ms N    domain cycle period in milliseconds (default 4)

alias EtherCAT.{Domain, Link, Master, Slave}
alias EtherCAT.Link.Transaction
alias EtherCAT.Slave.Registers

# ---------------------------------------------------------------------------
# Driver definitions
# ---------------------------------------------------------------------------

defmodule Example.EL1809 do
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile(_config) do
    %{
      channels: %{
        inputs_size:  2,
        outputs_size: 0,
        sms:   [{0, 0x1000, 2, 0x20}],
        fmmus: [{0, 0x1000, 2, :read}]
      }
    }
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
    %{
      outputs: %{
        inputs_size:  0,
        outputs_size: 2,
        sms:   [{0, 0x0F00, 1, 0x44}, {1, 0x0F01, 1, 0x44}],
        fmmus: [{0, 0x0F00, 2, :write}]
      }
    }
  end

  @impl true
  def encode_outputs(:outputs, _config, v) when is_integer(v), do: <<v::16-little>>
  def encode_outputs(_pdo, _config, _), do: <<0, 0>>

  @impl true
  def decode_inputs(_pdo, _config, _), do: nil
end

# ---------------------------------------------------------------------------
# Phase loop
#
# Runs until {:phase_done, ref} arrives.  On each :tick it calls set_fn/1
# and writes the result to the valve output.  On each {:slave_input, ...}
# it checks the received value against the last written value (one-tick
# loopback) and counts mismatches.
#
# Returns {ticks_sent, mismatch_count}.
# ---------------------------------------------------------------------------

defmodule Example.PhaseLoop do
  def run(set_fn, phase_ref) do
    loop(set_fn, phase_ref, 0, nil, 0, 0)
  end

  defp loop(set_fn, phase_ref, ticks, last_out, mismatches, last_print) do
    receive do
      {:phase_done, ^phase_ref} ->
        {ticks, mismatches}

      :tick ->
        expected = set_fn.(ticks)
        Slave.set_output(:valve, :outputs, expected)
        loop(set_fn, phase_ref, ticks + 1, expected, mismatches, last_print)

      {:slave_input, :sensor, :channels, actual} ->
        mismatch = if last_out != nil and actual != last_out, do: 1, else: 0

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

        loop(set_fn, phase_ref, ticks, last_out, mismatches + mismatch, new_print)
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

run_phase = fn label, set_fn, duration_ms, period_ms ->
  banner.("Phase: #{label}  (#{duration_ms} ms @ #{period_ms} ms/tick)")

  drain_mailbox.()
  {:ok, s_before} = Domain.stats(:main)

  phase_ref = make_ref()
  Process.send_after(self(), {:phase_done, phase_ref}, duration_ms)
  {:ok, tick_timer} = :timer.send_interval(period_ms, self(), :tick)

  {ticks, mismatches} = Example.PhaseLoop.run(set_fn, phase_ref)

  :timer.cancel(tick_timer)
  drain_mailbox.()

  {:ok, s_after} = Domain.stats(:main)
  miss_delta = s_after.miss_count - s_before.miss_count

  IO.puts("  ticks        : #{ticks}")
  IO.puts("  frame misses : #{miss_delta}")
  IO.puts("  loopback err : #{mismatches}")

  %{miss_delta: miss_delta, ticks: ticks, mismatches: mismatches}
end

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

{opts, _, _} =
  OptionParser.parse(System.argv(),
    switches: [interface: :string, period_ms: :integer]
  )

interface = opts[:interface] || raise "pass --interface, e.g. --interface enp0s31f6"
period_ms = Keyword.get(opts, :period_ms, 4)

IO.puts("""
EtherCAT hardware stress test
  interface : #{interface}
  period    : #{period_ms} ms
""")

# ---------------------------------------------------------------------------
# 1. Master start + slave discovery
# ---------------------------------------------------------------------------

banner.("1. Master start + slave discovery")

Master.stop()
Process.sleep(300)

check.("Master.start", Master.start(
  interface: interface,
  slaves: [
    nil,
    [name: :sensor, driver: Example.EL1809, config: %{}],
    [name: :valve,  driver: Example.EL2809, config: %{}]
  ]
))

Process.sleep(600)

slaves = Master.slaves()
IO.puts("  #{length(slaves)} named slave(s):")

for {name, station, _pid} <- slaves do
  id    = Slave.identity(name)
  state = Slave.state(name)
  id_str = if id, do: "vendor=#{hex8.(id.vendor_id)} product=#{hex8.(id.product_code)}", else: "(no identity)"
  IO.puts("  #{inspect(name)} @ #{hex.(station)}: #{state}  #{id_str}")
end

if slaves == [], do: raise("No named slaves — check cabling and slave config")

link = Master.link()

# ---------------------------------------------------------------------------
# 2. Domain setup
# ---------------------------------------------------------------------------

banner.("2. Domain setup")

check.("DomainSupervisor.start_child", DynamicSupervisor.start_child(
  EtherCAT.DomainSupervisor,
  {EtherCAT.Domain, id: :main, link: link, period: period_ms, miss_threshold: 500}
))

check.("register_pdo :sensor :channels", Slave.register_pdo(:sensor, :channels, :main))
check.("register_pdo :valve  :outputs",  Slave.register_pdo(:valve,  :outputs,  :main))

Slave.subscribe(:sensor, :channels, self())

# ---------------------------------------------------------------------------
# 3. Activate + go op
# ---------------------------------------------------------------------------

banner.("3. Activate + op")

Enum.each(slaves, fn {name, _, _} -> Slave.request(name, :safeop) end)
check.("Domain.activate", Domain.activate(:main))
Enum.each(slaves, fn {name, _, _} -> Slave.request(name, :op) end)

Process.sleep(100)

for {name, station, _} <- slaves do
  IO.puts("  #{inspect(name)} @ #{hex.(station)}: #{Slave.state(name)}")
end

{:ok, s0} = Domain.stats(:main)
IO.puts("  image_size=#{s0.image_size} bytes  state=#{s0.state}")

# ---------------------------------------------------------------------------
# Pattern definitions
# ---------------------------------------------------------------------------

phase_ms = 5_000

# Walking single bit (bit 0 → bit 15, repeat)
walking_one = fn tick -> Bitwise.bsl(1, rem(tick, 16)) end

# Checkerboard: 0x5555 / 0xAAAA toggle every tick
checkerboard = fn tick ->
  if rem(tick, 2) == 0, do: 0x5555, else: 0xAAAA
end

# All-ON / ALL-OFF, hold 20 ticks per state
slow_toggle = fn tick ->
  if rem(div(tick, 20), 2) == 0, do: 0xFFFF, else: 0x0000
end

# 16-bit Galois LFSR (taps: 16,15,13,4 → feedback mask 0xB400)
# Deterministic, full-period (65535 steps)
lfsr = :atomics.new(1, [])
:atomics.put(lfsr, 1, 0xACE1)

lfsr_fn = fn _tick ->
  s = :atomics.get(lfsr, 1)
  lsb  = Bitwise.band(s, 1)
  next = Bitwise.bsr(s, 1)
  next = if lsb == 1, do: Bitwise.bxor(next, 0xB400), else: next
  :atomics.put(lfsr, 1, next)
  next
end

# Burst stress: max update rate (every tick at the configured period)
burst_toggle = fn tick ->
  if rem(tick, 2) == 0, do: 0xFFFF, else: 0x0000
end

# ---------------------------------------------------------------------------
# 4. Stress phases
# ---------------------------------------------------------------------------

banner.("4. Stress phases  (#{phase_ms} ms each)")

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
# 5. Zero outputs + stop cyclic
# ---------------------------------------------------------------------------

Slave.set_output(:valve, :outputs, 0x0000)
Process.sleep(2 * period_ms)
Domain.stop_cyclic(:main)

# ---------------------------------------------------------------------------
# 6. Final report
# ---------------------------------------------------------------------------

banner.("5. Final report")

{:ok, final} = Domain.stats(:main)
IO.puts("  Total domain cycles : #{final.cycle_count}")
IO.puts("  Total frame misses  : #{final.miss_count}")
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
{rx_addr, rx_size} = Registers.rx_error_counter()

for {name, station, _} <- slaves do
  case Link.transaction(link, &Transaction.fprd(&1, station, rx_addr, rx_size)) do
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
Master.stop()
IO.puts("  OK\n")
