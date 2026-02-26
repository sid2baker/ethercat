#!/usr/bin/env elixir
# End-to-end hardware test for the EtherCAT stack using the Domain API.
#
# Tests: Master → Slave ESM → SII EEPROM → Domain self-timed cyclic I/O.
#
# Usage:
#   mix run examples/hardware_test.exs --interface enp0s31f6
#
# Optional flags:
#   --cycles N       number of cyclic I/O rounds to wait for (default 100)
#   --period-ms N    domain cycle period in milliseconds (default 4)
#
# Expected hardware setup:
#   EL1809 (16-ch digital input)  at station 0x1001
#   EL2809 (16-ch digital output) at station 0x1002

alias EtherCAT.{Domain, Master, Slave}

# ---------------------------------------------------------------------------
# Driver definitions (inline — new pdos-list format)
# ---------------------------------------------------------------------------

defmodule Example.EL1809 do
  @moduledoc "EL1809 — 16-channel 24V digital input terminal"
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile do
    %{pdos: [%{
      domain:       :default,
      outputs_size: 0,
      inputs_size:  2,
      sms:          [{0, 0x1000, 2, 0x20}],
      fmmus:        [{0, 0x1000, 2, :read}]
    }]}
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
    %{pdos: [%{
      domain:       :default,
      outputs_size: 2,
      inputs_size:  0,
      sms:          [{0, 0x0F00, 1, 0x44}, {1, 0x0F01, 1, 0x44}],
      fmmus:        [{1, 0x0F00, 2, :write}]
    }]}
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
EtherCAT hardware test (Domain API)
  interface : #{interface}
  cycles    : #{cycles}
  period    : #{period_ms} ms
""")

# Register drivers before Master.start — slaves look up drivers during :init→:preop
# (SII EEPROM is read then find_driver/2 is called; must be in app env by then)
Application.put_env(:ethercat, :drivers, %{
  {0x00000002, 0x07113052} => Example.EL1809,
  {0x00000002, 0x0AF93052} => Example.EL2809
})

# ---------------------------------------------------------------------------
# 1. Start master + slave discovery
# ---------------------------------------------------------------------------

banner.("1. Master start + slave discovery")

# Stop any leftover master from a previous run (idempotent)
Master.stop()
Process.sleep(200)

check.("Master.start", Master.start(interface: interface))

# Wait for slaves to auto-advance to :preop (reads SII EEPROM)
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
  else
    IO.puts("  #{hex.(station)}: SII not read yet")
  end
end

# ---------------------------------------------------------------------------
# 3. Configure domain BEFORE advancing to :safeop
#    Slaves self-register their PDOs when they enter :safeop
# ---------------------------------------------------------------------------

banner.("3. Domain setup")

link = Master.link()

check.("DomainSupervisor.start_child", DynamicSupervisor.start_child(
  EtherCAT.DomainSupervisor,
  {EtherCAT.Domain, id: :default_domain, link: link, period: period_ms, miss_threshold: 10_000}
))

check.("Domain.set_default", Domain.set_default(:default_domain))

IO.puts("  Domain :default_domain armed at #{period_ms} ms period")
IO.puts("  Slaves will self-register PDOs when they enter :safeop")

# ---------------------------------------------------------------------------
# 4. Advance to SafeOp — triggers PDO self-registration
# ---------------------------------------------------------------------------

banner.("4. ESM: preop → safeop (PDO registration)")

Enum.each(slaves, fn {station, _} ->
  case Slave.request(station, :safeop) do
    :ok -> :ok
    {:error, reason} ->
      IO.puts("  WARNING: #{hex.(station)} safeop failed: #{inspect(reason)}")
  end
end)

Process.sleep(200)

for {station, _} <- slaves do
  state = Slave.state(station)
  err   = Slave.error(station)
  err_str = if err, do: "  [AL error 0x#{Integer.to_string(err, 16)}]", else: ""
  IO.puts("  #{hex.(station)}: #{state}#{err_str}")
end

{:ok, stats} = Domain.stats(:default_domain)
IO.puts("  Domain image_size: #{stats.image_size} bytes")

# ---------------------------------------------------------------------------
# 5. Advance to Op + start cycling
# ---------------------------------------------------------------------------

banner.("5. ESM: safeop → op + start cyclic")

Enum.each(slaves, fn {station, _} ->
  case Slave.request(station, :op) do
    :ok -> :ok
    {:error, reason} ->
      IO.puts("  WARNING: #{hex.(station)} op failed: #{inspect(reason)}")
  end
end)

Process.sleep(100)

for {station, _} <- slaves do
  IO.puts("  #{hex.(station)}: #{Slave.state(station)}")
end

check.("Domain.start_cyclic", Domain.start_cyclic(:default_domain))
Domain.subscribe(:default_domain)
IO.puts("  Domain cycling at #{period_ms} ms period")

# ---------------------------------------------------------------------------
# 6. Cyclic I/O loop — react to cycle_done notifications
# ---------------------------------------------------------------------------

banner.("6. Cyclic I/O — #{cycles} cycles at #{period_ms} ms")

in_station  = 0x1001
out_station = 0x1002

IO.puts("  output slave : #{hex.(out_station)}  (EL2809)")
IO.puts("  input  slave : #{hex.(in_station)}   (EL1809)")
IO.puts("")

timings = :array.new(cycles, default: 0)

{timings, _} =
  Enum.reduce(0..(cycles - 1), {timings, nil}, fn step, {timings, last_in} ->
    t0 = System.monotonic_time(:microsecond)

    receive do
      {:ethercat_domain, :default_domain, :cycle_done} ->
        {:ok, in_raw, _ts} = Domain.get_inputs(:default_domain, in_station)
        in_val = Example.EL1809.decode_inputs(in_raw)

        phase   = div(step, 25)
        on?     = rem(phase, 2) == 0
        out_raw = Example.EL2809.encode_outputs(if on?, do: 0xFFFF, else: 0x0000)
        Domain.put_outputs(:default_domain, out_station, out_raw)

        if in_val != last_in or rem(step, 25) == 0 do
          IO.puts(
            "  step=#{String.pad_leading(to_string(step), 4)}  " <>
              "out=#{if on?, do: "ALL_ON ", else: "ALL_OFF"}  " <>
              "inputs=#{hex.(in_val)}"
          )
        end

        t1 = System.monotonic_time(:microsecond)
        {:array.set(step, t1 - t0, timings), in_val}

    after 500 ->
      {:ok, s} = Domain.stats(:default_domain)
      IO.puts("  step=#{step}: timeout  state=#{s.state} cycles=#{s.cycle_count} misses=#{s.miss_count}")
      {timings, last_in}
    end
  end)

Domain.stop_cyclic(:default_domain)

# ---------------------------------------------------------------------------
# 7. Timing report
# ---------------------------------------------------------------------------

banner.("7. Timing report")

all_times = for i <- 0..(cycles - 1), do: :array.get(i, timings)
valid = Enum.filter(all_times, &(&1 > 0))

if valid != [] do
  min_us = Enum.min(valid)
  max_us = Enum.max(valid)
  avg_us = div(Enum.sum(valid), length(valid))
  target = period_ms * 1000

  IO.puts("  cycles  : #{length(valid)}")
  IO.puts("  target  : #{target} µs  (#{period_ms} ms)")
  IO.puts("  min     : #{min_us} µs")
  IO.puts("  avg     : #{avg_us} µs")
  IO.puts("  max     : #{max_us} µs")
  IO.puts("  jitter  : #{max_us - min_us} µs")

  overruns = Enum.count(valid, &(&1 > target * 1.5))
  IO.puts("  overruns (>1.5× target): #{overruns}")
end

{:ok, final_stats} = Domain.stats(:default_domain)
IO.puts("  domain cycle_count : #{final_stats.cycle_count}")
IO.puts("  domain miss_count  : #{final_stats.miss_count}")

# ---------------------------------------------------------------------------
# 8. ESC error counters
# ---------------------------------------------------------------------------

banner.("8. ESC error counters")

{rx_addr, rx_size} = EtherCAT.Slave.Registers.rx_error_counter()

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
