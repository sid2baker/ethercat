#!/usr/bin/env elixir
# Quick I/O cycle test using the current EtherCAT.Master + EtherCAT.Slave stack.
#
# Usage:
#   mix run examples/io_quick.exs --interface enp0s31f6 [--cycles 200] [--period-ms 10]
#
# What it does:
#   1. Starts the master → scans slaves → slaves auto-advance to :preop
#   2. Advances all slaves to :op via Master.go_operational()
#   3. Runs N cycles of LWR (logical write) + LRD (logical read) using the
#      FMMU mappings configured in step 3 (hard-coded for the 3-slave setup
#      seen in hardware: coupler + output module + input module).
#   4. Prints input word whenever it changes, plus a heartbeat every 50 cycles.

alias EtherCAT.{Command, Link, Master, Slave}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

{opts, _, _} =
  OptionParser.parse(System.argv(),
    switches: [interface: :string, cycles: :integer, period_ms: :integer]
  )

interface = opts[:interface] || raise "pass --interface enp0s31f6"
cycles = Keyword.get(opts, :cycles, 200)
period_ms = Keyword.get(opts, :period_ms, 10)

IO.puts("Interface : #{interface}")
IO.puts("Cycles    : #{cycles}  Period: #{period_ms} ms")

# ---------------------------------------------------------------------------
# Start master + wait for slaves to reach :preop
# ---------------------------------------------------------------------------

:ok = Master.start(interface: interface)
Process.sleep(500)

slave_list = Master.slaves()
IO.puts("\nSlaves discovered: #{length(slave_list)}")

for {station, _pid} <- slave_list do
  state = Slave.state(station)
  id = Slave.identity(station)

  id_str =
    if id,
      do:
        "vendor=0x#{Integer.to_string(id.vendor_id, 16)} " <>
          "product=0x#{Integer.to_string(id.product_code, 16)}",
      else: "(no identity)"

  IO.puts("  0x#{Integer.to_string(station, 16)}: #{state}  #{id_str}")
end

# ---------------------------------------------------------------------------
# Advance all to :op
# ---------------------------------------------------------------------------

IO.puts("\nAdvancing all slaves to :op ...")
:ok = Master.go_operational()
Process.sleep(200)

IO.puts("Slave states after go_operational:")

for {station, _pid} <- slave_list do
  IO.puts("  0x#{Integer.to_string(station, 16)}: #{Slave.state(station)}")
end

# ---------------------------------------------------------------------------
# Configure SMs and FMMUs for the 3-slave layout seen on this hardware:
#   0x1000 — coupler (no SM/FMMU needed)
#   0x1001 — output module: SM0@0x0F00 len=1 ctrl=0x44, FMMU → logical 0x0000
#   0x1002 — input  module: SM0@0x1000 len=2 ctrl=0x20, FMMU → logical 0x0010
# ---------------------------------------------------------------------------

link = Master.link()

sm_out = fn start, len, ctrl ->
  <<start::16-little, len::16-little, ctrl::8, 0::8, 0x01::8, 0::8>>
end

fmmu = fn log_start, size, phys_start, dir ->
  type = if dir == :read, do: 0x01, else: 0x02
  <<log_start::32-little, size::16-little, 0::8, 7::8,
    phys_start::16-little, 0::8, type::8, 0x01::8, 0::24>>
end

out_station = 0x1001
in_station  = 0x1002

IO.puts("\nConfiguring SMs ...")
{:ok, _} = Link.transact(link, [Command.fpwr(out_station, 0x0800, sm_out.(0x0F00, 1, 0x44))])
{:ok, _} = Link.transact(link, [Command.fpwr(out_station, 0x0808, sm_out.(0x0F01, 1, 0x44))])
{:ok, _} = Link.transact(link, [Command.fpwr(in_station,  0x0800, sm_out.(0x1000, 2, 0x20))])

IO.puts("Configuring FMMUs ...")
{:ok, _} = Link.transact(link, [Command.fpwr(out_station, 0x0600, fmmu.(0x0000, 2, 0x0F00, :write))])
{:ok, _} = Link.transact(link, [Command.fpwr(in_station,  0x0600, fmmu.(0x0010, 2, 0x1000, :read))])

# ---------------------------------------------------------------------------
# Cycle loop: LWR outputs, LRD inputs
# ---------------------------------------------------------------------------

IO.puts("\nRunning #{cycles} cycles (#{period_ms} ms period) ...")
IO.puts("Press Ctrl-C to stop early.\n")

Enum.reduce(0..(cycles - 1), nil, fn step, last_inputs ->
  phase   = div(step, 50)
  on?     = rem(phase, 2) == 0
  out_val = if on?, do: 0xFF, else: 0x00

  {:ok, [_wr, %{data: <<inputs::16-little>>}]} =
    Link.transact(link, [
      Command.lwr(0x0000, <<out_val, out_val>>),
      Command.lrd(0x0010, 2)
    ])

  if inputs != last_inputs or rem(step, 50) == 0 do
    IO.puts(
      "step=#{String.pad_leading(to_string(step), 4)} " <>
        "out=#{if(on?, do: "ON ", else: "off")} " <>
        "inputs=0x#{String.pad_leading(Integer.to_string(inputs, 16), 4, "0")}"
    )
  end

  Process.sleep(period_ms)
  inputs
end)

IO.puts("\nDone.")
Master.stop()
