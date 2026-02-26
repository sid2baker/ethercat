#!/usr/bin/env elixir
# End-to-end hardware test for the EtherCAT stack.
#
# Tests the full implementation: Master → Slave ESM → SII EEPROM → ProcessImage.
#
# Usage:
#   mix run examples/hardware_test.exs --interface enp0s31f6
#
# Optional flags:
#   --cycles N       number of cyclic I/O rounds (default 100)
#   --period-ms N    cycle period in milliseconds (default 4)
#
# Expected hardware setup:
#   EL1809 (16-ch digital input)  at station 0x1001
#   EL2809 (16-ch digital output) at station 0x1002
#
# What this tests:
#   1. Link layer  — BRD detects slaves
#   2. ESM         — all slaves reach :op
#   3. SII EEPROM  — vendor/product IDs read correctly
#   4. ProcessImage — SM/FMMU configured, LRW cycle runs at target period
#   5. Driver contract — encode_outputs/decode_inputs boundary is honoured
#   6. Timing      — measures actual cycle jitter over N rounds

alias EtherCAT.{Master, Slave}
alias EtherCAT.Slave.{ProcessImage, Registers}

# ---------------------------------------------------------------------------
# Driver definitions (inline for self-contained example)
# ---------------------------------------------------------------------------

defmodule Example.EL1809 do
  @moduledoc "EL1809 — 16-channel 24V digital input terminal"
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile do
    %{
      outputs_size: 0,
      inputs_size: 2,
      sms:   [{3, 0x1000, 2, 0x20}],
      fmmus: [{1, 0x1000, 2, :read}]
    }
  end

  @impl true
  def encode_outputs(_), do: <<>>

  @impl true
  def decode_inputs(<<channels::16-little>>), do: channels
  def decode_inputs(_), do: 0
end

defmodule Example.EL2809 do
  @moduledoc "EL2809 — 16-channel 24V digital output terminal"
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile do
    %{
      outputs_size: 2,
      inputs_size: 0,
      sms:   [{2, 0x0F00, 2, 0x44}],
      fmmus: [{0, 0x0F00, 2, :write}]
    }
  end

  @impl true
  def encode_outputs(channels) when is_integer(channels), do: <<channels::16-little>>
  def encode_outputs(_), do: <<0, 0>>

  @impl true
  def decode_inputs(_), do: nil
end

# ---------------------------------------------------------------------------
# Helpers (anonymous fns — .exs top-level can't import same-file modules)
# ---------------------------------------------------------------------------

hex  = fn n -> "0x#{String.pad_leading(Integer.to_string(n, 16), 4, "0")}" end
hex8 = fn n -> "0x#{String.pad_leading(Integer.to_string(n, 16), 8, "0")}" end

banner = fn title ->
  IO.puts("\n── #{title} " <> String.duplicate("─", max(0, 60 - String.length(title))))
end

check = fn label, result ->
  case result do
    :ok ->
      IO.puts("  ✓ #{label}")
      :ok

    {:ok, val} ->
      IO.puts("  ✓ #{label}: #{inspect(val)}")
      val

    {:error, reason} ->
      IO.puts("  ✗ #{label}: #{inspect(reason)}")
      raise "FAIL: #{label} — #{inspect(reason)}"
  end
end

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

{opts, _, _} =
  OptionParser.parse(System.argv(),
    switches: [interface: :string, cycles: :integer, period_ms: :integer]
  )

interface = opts[:interface] || raise "pass --interface, e.g. --interface enp0s31f6"
cycles    = Keyword.get(opts, :cycles, 100)
period_ms = Keyword.get(opts, :period_ms, 4)

IO.puts("""
EtherCAT hardware test
  interface : #{interface}
  cycles    : #{cycles}
  period    : #{period_ms} ms
""")

# Build profile map keyed by product code (from SII, resolved at configure time)
# EL1809 product code: 0x07113052
# EL2809 product code: 0x0AF93052
profiles = %{
  0x07113052 => Example.EL1809.process_data_profile(),
  0x0AF93052 => Example.EL2809.process_data_profile()
}

# ---------------------------------------------------------------------------
# 1. Start master + slave discovery
# ---------------------------------------------------------------------------

banner.("1. Master start + slave discovery")

check.("Master.start", Master.start(interface: interface))
Process.sleep(500)

slaves = Master.slaves()
IO.puts("  Found #{length(slaves)} slave(s)")

for {station, _pid} <- slaves do
  id    = Slave.identity(station)
  state = Slave.state(station)

  id_str =
    if id do
      "vendor=#{hex8.(id.vendor_id)} product=#{hex8.(id.product_code)} " <>
        "rev=#{hex8.(id.revision)} sn=#{hex8.(id.serial_number)}"
    else
      "(no identity)"
    end

  IO.puts("  #{hex.(station)}: #{state}  #{id_str}")
end

if slaves == [], do: raise("No slaves found — check cabling and interface name")

# ---------------------------------------------------------------------------
# 2. SII EEPROM verification
# ---------------------------------------------------------------------------

banner.("2. SII EEPROM identity check")

for {station, _pid} <- slaves do
  id = Slave.identity(station)

  if id do
    IO.puts("  #{hex.(station)}: vendor=#{hex8.(id.vendor_id)} product=#{hex8.(id.product_code)}")
    driver = Application.get_env(:ethercat, :drivers, profiles) |> Map.get({id.vendor_id, id.product_code})
    if driver, do: IO.puts("         driver : #{inspect(driver)}")
  else
    IO.puts("  #{hex.(station)}: SII not read yet (still in :init?)")
  end
end

# ---------------------------------------------------------------------------
# 3. Advance to Op
# ---------------------------------------------------------------------------

banner.("3. ESM: preop → safeop → op")

check.("go_operational", Master.go_operational())
Process.sleep(200)

for {station, _} <- slaves do
  state = Slave.state(station)
  err   = Slave.error(station)
  err_str = if err, do: "  [AL error 0x#{Integer.to_string(err, 16)}]", else: ""
  IO.puts("  #{hex.(station)}: #{state}#{err_str}")
end

all_op = Enum.all?(slaves, fn {station, _} -> Slave.state(station) == :op end)
unless all_op, do: IO.puts("  WARNING: not all slaves reached :op")

# ---------------------------------------------------------------------------
# 4. Configure SM + FMMU (process image)
# ---------------------------------------------------------------------------

banner.("4. ProcessImage.configure (SM + FMMU)")

# Store profiles in app env so Master.configure() picks them up, then also
# call ProcessImage.configure directly to inspect the layout.
Application.put_env(:ethercat, :io_profiles, profiles)
check.("Master.configure", Master.configure())

link = Master.link()
{:ok, layout} = ProcessImage.configure(link, slaves, profiles)
IO.puts("  image_size : #{layout.image_size} bytes")
IO.puts("  outputs    : #{inspect(layout.outputs)}")
IO.puts("  inputs     : #{inspect(layout.inputs)}")

# ---------------------------------------------------------------------------
# 5. Cyclic I/O loop
# ---------------------------------------------------------------------------

banner.("5. Cyclic I/O — #{cycles} cycles at #{period_ms} ms")

in_station  = 0x1001
out_station = 0x1002

IO.puts("  output slave : #{hex.(out_station)}  (EL2809)")
IO.puts("  input  slave : #{hex.(in_station)}   (EL1809)")
IO.puts("")

timings = :array.new(cycles, default: 0)

{timings, _last_in, _} =
  Enum.reduce(0..(cycles - 1), {timings, nil, nil}, fn step, {timings, last_in, _last_out} ->
    t0 = System.monotonic_time(:microsecond)

    # Blink pattern: alternate every 25 cycles
    phase   = div(step, 25)
    on?     = rem(phase, 2) == 0
    out_raw = Example.EL2809.encode_outputs(if on?, do: 0xFFFF, else: 0x0000)

    case Master.cycle(%{out_station => out_raw}) do
      {:ok, inputs} ->
        in_raw = Map.get(inputs, in_station, <<0, 0>>)
        in_val = Example.EL1809.decode_inputs(in_raw)

        if in_val != last_in or rem(step, 25) == 0 do
          IO.puts(
            "  step=#{String.pad_leading(to_string(step), 4)}  " <>
              "out=#{if on?, do: "ALL_ON ", else: "ALL_OFF"}  " <>
              "inputs=#{hex.(in_val)}"
          )
        end

        elapsed = System.monotonic_time(:microsecond) - t0
        Process.sleep(max(0, period_ms - div(elapsed, 1000)))

        t1 = System.monotonic_time(:microsecond)
        {:array.set(step, t1 - t0, timings), in_val, out_raw}

      {:error, reason} ->
        IO.puts("  step=#{step} cycle error: #{inspect(reason)}")
        Process.sleep(period_ms)
        {timings, last_in, nil}
    end
  end)

# ---------------------------------------------------------------------------
# 6. Timing report
# ---------------------------------------------------------------------------

banner.("6. Timing report")

all_times = for i <- 0..(cycles - 1), do: :array.get(i, timings)
valid = Enum.filter(all_times, &(&1 > 0))

if valid != [] do
  min_us  = Enum.min(valid)
  max_us  = Enum.max(valid)
  avg_us  = div(Enum.sum(valid), length(valid))
  target  = period_ms * 1000

  IO.puts("  cycles  : #{length(valid)}")
  IO.puts("  target  : #{target} µs  (#{period_ms} ms)")
  IO.puts("  min     : #{min_us} µs")
  IO.puts("  avg     : #{avg_us} µs")
  IO.puts("  max     : #{max_us} µs")
  IO.puts("  jitter  : #{max_us - min_us} µs")

  overruns = Enum.count(valid, &(&1 > target * 1.5))
  IO.puts("  overruns (>1.5× target): #{overruns}")
end

# ---------------------------------------------------------------------------
# 7. Error counter snapshot
# ---------------------------------------------------------------------------

banner.("7. ESC error counters")

{rx_addr, rx_size} = Registers.rx_error_counter()

for {station, _} <- slaves do
  case EtherCAT.Link.transaction(link, &EtherCAT.Link.Transaction.fprd(&1, station, rx_addr, rx_size)) do
    {:ok, [%{data: <<p0::16-little, p1::16-little, p2::16-little, p3::16-little>>, wkc: wkc}]}
    when wkc > 0 ->
      IO.puts("  #{hex.(station)}: rx_errors port0=#{p0} port1=#{p1} port2=#{p2} port3=#{p3}")

    _ ->
      IO.puts("  #{hex.(station)}: could not read error counters")
  end
end

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

banner.("Done")
IO.puts("  Stopping master...")
Master.stop()
IO.puts("  OK\n")
