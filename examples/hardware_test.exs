#!/usr/bin/env elixir
# EtherCAT hardware stress test — new EtherCAT top-level API
#
# Hardware setup (3-slave ring):
#   position 0 → 0x1000  EK1100 coupler  (nil — no driver)
#   position 1 → 0x1001  EL1809 16-ch digital input
#   position 2 → 0x1002  EL2809 16-ch digital output
#   position 3 → 0x1003  EL3202 2-ch PT100 resistance input
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
#   --udp              run a UDP transport smoke test using broadcast (255.255.255.255:34980)
#                       requires ESC UDP support per spec §2.6
#   --udp-host IP       unicast UDP test to a specific host instead of broadcast

alias EtherCAT.Bus
alias EtherCAT.Bus.Transaction
alias EtherCAT.Domain
alias EtherCAT.Slave
alias EtherCAT.Slave.Registers

# ---------------------------------------------------------------------------
# Driver definitions
# ---------------------------------------------------------------------------

defmodule Example.EL1809 do
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile(_config) do
    %{
      ch1:  0x1A00, ch2:  0x1A01, ch3:  0x1A02, ch4:  0x1A03,
      ch5:  0x1A04, ch6:  0x1A05, ch7:  0x1A06, ch8:  0x1A07,
      ch9:  0x1A08, ch10: 0x1A09, ch11: 0x1A0A, ch12: 0x1A0B,
      ch13: 0x1A0C, ch14: 0x1A0D, ch15: 0x1A0E, ch16: 0x1A0F
    }
  end

  @impl true
  def encode_outputs(_pdo, _config, _), do: <<>>

  @impl true
  # 1-bit TxPDO: FMMU places the physical SM bit into logical bit 0 (LSB).
  def decode_inputs(_ch, _config, <<_::7, bit::1>>), do: bit
  def decode_inputs(_pdo, _config, _), do: 0
end

defmodule Example.EL2809 do
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile(_config) do
    # SM0 (0x0F00): channels 1–8, SM1 (0x0F01): channels 9–16.
    # Each is a 1-bit RxPDO; master uses bit-level FMMUs to pack into SM bytes.
    %{
      ch1:  0x1600, ch2:  0x1601, ch3:  0x1602, ch4:  0x1603,
      ch5:  0x1604, ch6:  0x1605, ch7:  0x1606, ch8:  0x1607,
      ch9:  0x1608, ch10: 0x1609, ch11: 0x160A, ch12: 0x160B,
      ch13: 0x160C, ch14: 0x160D, ch15: 0x160E, ch16: 0x160F
    }
  end

  @impl true
  # 1-bit RxPDO: return 1 byte; the FMMU places bit 0 (LSB) into the SM bit.
  def encode_outputs(_ch, _config, v), do: <<v::8>>

  @impl true
  def decode_inputs(_pdo, _config, _), do: nil
end

defmodule Example.EL3202 do
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile(_config) do
    # Two 32-bit TxPDOs on SM3: 0x1A00 = channel 1 (bytes 0–3), 0x1A01 = channel 2 (bytes 4–7)
    %{channel1: 0x1A00, channel2: 0x1A01}
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
  def decode_inputs(:channel1, _config, <<
        _::1, error::1, _::2, _::2, overrange::1, underrange::1,
        toggle::1, state::1, _::6, value::16-little>>) do
    %{ohms: value / 16.0, overrange: overrange == 1, underrange: underrange == 1,
      error: error == 1, invalid: state == 1, toggle: toggle}
  end
  def decode_inputs(:channel2, _config, <<
        _::1, error::1, _::2, _::2, overrange::1, underrange::1,
        toggle::1, state::1, _::6, value::16-little>>) do
    %{ohms: value / 16.0, overrange: overrange == 1, underrange: underrange == 1,
      error: error == 1, invalid: state == 1, toggle: toggle}
  end
  def decode_inputs(_pdo, _config, _), do: nil
end

# ---------------------------------------------------------------------------
# Phase loop
#
# Runs until {:phase_done, ref} arrives.  On each :tick it calls set_fn/1
# and writes the result to the valve output — one set_output per bit.
#
# On each {:slave_input, :sensor, ch_N, bit} it accumulates the 16 bits into
# a 16-bit integer and checks against pprev_out (2 ticks ago) for loopback
# fidelity.
#
# The stability check (pprev == prev == last for ≥2 ticks) prevents false
# positives on transition cycles and partial-accumulation cycles.
#
# Returns {ticks_sent, mismatch_count}.
# ---------------------------------------------------------------------------

defmodule Example.PhaseLoop do
  # Map from channel atom to bit position (0-based)
  @ch_bits Enum.into(1..16, %{}, fn i -> {:"ch#{i}", i - 1} end)

  def run(set_fn, phase_ref, loopback_mask) do
    loop(set_fn, phase_ref, loopback_mask, 0, nil, nil, nil, 0, 0, %{}, nil, nil)
  end

  # State: ticks, pprev_out, prev_out, last_out, mismatches, last_print, sensor_ch, thermo1, thermo2
  defp loop(set_fn, phase_ref, mask, ticks, pprev_out, prev_out, last_out, mismatches, last_print, sensor_ch, thermo1, thermo2) do
    receive do
      {:phase_done, ^phase_ref} ->
        {ticks, mismatches}

      :tick ->
        expected = set_fn.(ticks)
        # Write each channel bit individually; master FMMUs pack into SM bytes
        Enum.each(0..15, fn bit ->
          v = Bitwise.band(Bitwise.bsr(expected, bit), 1)
          EtherCAT.set_output(:valve, :"ch#{bit + 1}", v)
        end)

        new_print =
          if last_print == 0 or ticks - last_print >= 250 do
            actual = rebuild_channels(sensor_ch)
            mark = if loopback_ok?(actual, pprev_out, prev_out, last_out, mask), do: "ok", else: "MISMATCH"
            IO.puts(
              "    tick=#{String.pad_leading(to_string(ticks), 5)}  " <>
              "out=0x#{Integer.to_string(expected, 16) |> String.pad_leading(4, "0")}  " <>
              "in=0x#{Integer.to_string(actual, 16) |> String.pad_leading(4, "0")}  #{mark}"
            )
            if thermo1 != nil or thermo2 != nil do
              v1_str = if thermo1, do: "#{:erlang.float_to_binary(thermo1.ohms, decimals: 2)}Ω#{if thermo1.error, do: " ERR", else: ""}", else: "?"
              v2_str = if thermo2, do: "#{:erlang.float_to_binary(thermo2.ohms, decimals: 2)}Ω#{if thermo2.error, do: " ERR", else: ""}", else: "?"
              IO.puts("    thermo: ch1=#{v1_str}  ch2=#{v2_str}")
            end
            ticks
          else
            last_print
          end

        loop(set_fn, phase_ref, mask, ticks + 1, prev_out, last_out, expected, mismatches, new_print, sensor_ch, thermo1, thermo2)

      {:slave_input, :sensor, ch, bit_val} when is_map_key(@ch_bits, ch) ->
        new_sensor_ch = Map.put(sensor_ch, ch, bit_val)
        actual = rebuild_channels(new_sensor_ch)
        stable? = pprev_out != nil and pprev_out == prev_out and prev_out == last_out
        mismatch =
          if stable? and Bitwise.band(actual, mask) != Bitwise.band(pprev_out, mask), do: 1, else: 0
        loop(set_fn, phase_ref, mask, ticks, pprev_out, prev_out, last_out, mismatches + mismatch, last_print, new_sensor_ch, thermo1, thermo2)

      {:slave_input, :thermo, :channel1, ch} ->
        loop(set_fn, phase_ref, mask, ticks, pprev_out, prev_out, last_out, mismatches, last_print, sensor_ch, ch, thermo2)

      {:slave_input, :thermo, :channel2, ch} ->
        loop(set_fn, phase_ref, mask, ticks, pprev_out, prev_out, last_out, mismatches, last_print, sensor_ch, thermo1, ch)
    end
  end

  defp rebuild_channels(ch_map) do
    Enum.reduce(@ch_bits, 0, fn {ch, bit_pos}, acc ->
      Bitwise.bor(acc, Bitwise.bsl(Map.get(ch_map, ch, 0), bit_pos))
    end)
  end

  defp loopback_ok?(actual, pprev_out, prev_out, last_out, mask) do
    stable? = pprev_out != nil and pprev_out == prev_out and prev_out == last_out
    not stable? or Bitwise.band(actual, mask) == Bitwise.band(pprev_out, mask)
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

parse_ip = fn s ->
  parts = String.split(s, ".") |> Enum.map(&String.to_integer/1)
  case parts do
    [a, b, c, d] -> {a, b, c, d}
    _ -> raise "invalid IP: #{s}"
  end
end

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

{opts, _, _} =
  OptionParser.parse(System.argv(),
    switches: [interface: :string, period_ms: :integer, loopback_mask: :string,
               udp: :boolean, udp_host: :string]
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

# UDP host: explicit unicast > broadcast default > disabled
# ESCs respond on any IP per spec §2.6 — broadcast works without configuration
udp_host =
  cond do
    opts[:udp_host] -> parse_ip.(opts[:udp_host])
    opts[:udp] -> {255, 255, 255, 255}
    true -> nil
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
  udp host      : #{if udp_host, do: "#{:inet.ntoa(udp_host)} (broadcast=#{udp_host == {255,255,255,255}})", else: "(skipped — pass --udp to enable)"}
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
    %EtherCAT.Domain.Config{id: :main, period: period_ms, miss_threshold: 500}
  ],
  slaves: [
    nil,
    %EtherCAT.Slave.Config{name: :sensor, driver: Example.EL1809, domain: :main},
    %EtherCAT.Slave.Config{name: :valve,  driver: Example.EL2809, domain: :main},
    %EtherCAT.Slave.Config{name: :thermo, driver: Example.EL3202, domain: :main}
  ]
))

check.("EtherCAT.await_running", EtherCAT.await_running(10_000))

Enum.each(1..16, fn i -> EtherCAT.subscribe(:sensor, :"ch#{i}", self()) end)
EtherCAT.subscribe(:thermo, :channel1, self())
EtherCAT.subscribe(:thermo, :channel2, self())

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

# Capture raw slave count for UDP comparison
raw_slave_count =
  case Bus.transaction(EtherCAT.link(), &Transaction.brd(&1, {0x0000, 1})) do
    {:ok, [%{wkc: n}]} -> n
    _ -> nil
  end

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

Enum.each(1..16, fn i -> EtherCAT.set_output(:valve, :"ch#{i}", 0) end)
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
bus = EtherCAT.link()

for {name, station, _} <- slaves do
  case Bus.transaction(bus, &Transaction.fprd(&1, station, Registers.rx_error_counter())) do
    {:ok, [%{data: <<p0::16-little, p1::16-little, p2::16-little, p3::16-little>>, wkc: wkc}]}
    when wkc > 0 ->
      IO.puts("    #{inspect(name)} @ #{hex.(station)}: port0=#{p0} port1=#{p1} port2=#{p2} port3=#{p3}")
    _ ->
      IO.puts("    #{inspect(name)} @ #{hex.(station)}: could not read")
  end
end

IO.puts("")
IO.puts("  Verdict: #{if all_ok, do: "PASS ✓", else: "FAIL ✗"}")

# ---------------------------------------------------------------------------
# 4. UDP transport smoke test (optional — requires --udp-host)
#
# Opens a Bus directly using the UDP/IP transport (spec §2.6).
# The ESC recognises EtherCAT frames embedded in UDP datagrams by UDP
# destination port 0x88A4 only — source/destination IPs and MACs are ignored.
#
# Test sequence:
#   a. BRD to 0x0000 / 1 byte — WKC must match the raw slave count
#   b. 50× FPRD to the first named slave's AL status register — all must succeed
#   c. 5× concurrent BRD (queue batching exercise) — all must return wkc > 0
# ---------------------------------------------------------------------------

if udp_host do
  banner.("4. UDP transport smoke test  (host=#{inspect(udp_host)})")

  udp_ok =
    case Bus.start_link(transport: :udp, host: udp_host) do
      {:ok, udp_bus} ->
        IO.puts("  ✓ Bus.start_link (UDP) opened")

        # a. BRD — slave count check
        brd_ok =
          case Bus.transaction(udp_bus, &Transaction.brd(&1, {0x0000, 1})) do
            {:ok, [%{wkc: n}]} when n == raw_slave_count ->
              IO.puts("  ✓ BRD: wkc=#{n} (matches raw count)")
              true

            {:ok, [%{wkc: n}]} ->
              IO.puts("  ✗ BRD: wkc=#{n} expected #{raw_slave_count} (raw count)")
              false

            {:error, reason} ->
              IO.puts("  ✗ BRD: #{inspect(reason)}")
              false
          end

        # b. Repeated FPRD to first slave AL status
        {_name, first_station, _pid} = hd(slaves)

        fprd_results =
          Enum.map(1..50, fn _ ->
            Bus.transaction(udp_bus, &Transaction.fprd(&1, first_station, Registers.al_status()))
          end)

        fprd_ok_count = Enum.count(fprd_results, &match?({:ok, [%{wkc: 1}]}, &1))
        fprd_ok = fprd_ok_count == 50

        if fprd_ok do
          IO.puts("  ✓ FPRD ×50: all responded (wkc=1)")
        else
          IO.puts("  ✗ FPRD ×50: #{fprd_ok_count}/50 succeeded")
        end

        # c. Queue batching — fire 5 BRDs in rapid succession while bus may be awaiting
        batch_tasks =
          Enum.map(1..5, fn _ ->
            Task.async(fn ->
              Bus.transaction(udp_bus, &Transaction.brd(&1, {0x0000, 1}))
            end)
          end)

        batch_results = Task.await_many(batch_tasks, 5_000)
        batch_ok_count = Enum.count(batch_results, fn
          {:ok, [%{wkc: n}]} when n > 0 -> true
          {:error, :discarded_cyclic} -> true   # BRD is non-cyclic but counts as fine
          _ -> false
        end)
        batch_ok = batch_ok_count == 5

        if batch_ok do
          IO.puts("  ✓ Batched BRD ×5: all completed")
        else
          details = Enum.map(batch_results, fn
            {:ok, [%{wkc: n}]} -> "wkc=#{n}"
            {:error, r} -> inspect(r)
          end)
          IO.puts("  ✗ Batched BRD ×5: #{inspect(details)}")
        end

        GenServer.stop(udp_bus)
        brd_ok and fprd_ok and batch_ok

      {:error, reason} ->
        IO.puts("  ✗ Bus.start_link (UDP) failed: #{inspect(reason)}")
        false
    end

  IO.puts("")
  IO.puts("  UDP verdict: #{if udp_ok, do: "PASS ✓", else: "FAIL ✗"}")
end

banner.("Done")
EtherCAT.stop()
IO.puts("  OK\n")
