#!/usr/bin/env elixir
# Cyclic I/O test using EtherCAT.Master + EtherCAT.IO.
#
# Usage:
#   mix run examples/io_quick.exs --interface enp0s31f6 [--cycles 200] [--period-ms 10]
#
# Flow:
#   1. Master starts → slaves forced to init → auto-advance to preop
#   2. go_operational  → all slaves to op
#   3. configure       → SM + FMMU registers written, process image layout built
#   4. cycle loop      → LRW each period, print inputs when they change

alias EtherCAT.{Master, Slave}

{opts, _, _} =
  OptionParser.parse(System.argv(),
    switches: [interface: :string, cycles: :integer, period_ms: :integer]
  )

interface = opts[:interface] || raise "pass --interface, e.g. --interface enp0s31f6"
cycles    = Keyword.get(opts, :cycles, 200)
period_ms = Keyword.get(opts, :period_ms, 10)

IO.puts("Interface : #{interface}")
IO.puts("Cycles    : #{cycles}  Period: #{period_ms} ms\n")

# -- Start ------------------------------------------------------------------

:ok = Master.start(interface: interface)
Process.sleep(500)

slaves = Master.slaves()
IO.puts("Slaves (#{length(slaves)}):")

for {station, _pid} <- slaves do
  state = Slave.state(station)
  id    = Slave.identity(station)
  id_str = if id, do: "vendor=0x#{Integer.to_string(id.vendor_id, 16)} product=0x#{Integer.to_string(id.product_code, 16)}", else: ""
  IO.puts("  0x#{Integer.to_string(station, 16)}: #{state}  #{id_str}")
end

# -- Operational ------------------------------------------------------------

IO.puts("\nAdvancing to :op ...")
:ok = Master.go_operational()
Process.sleep(200)

for {station, _} <- slaves do
  IO.puts("  0x#{Integer.to_string(station, 16)}: #{Slave.state(station)}")
end

# -- Configure SM + FMMU ----------------------------------------------------

IO.puts("\nConfiguring process image ...")
:ok = Master.configure()
IO.puts("Done.\n")

# -- Cycle loop -------------------------------------------------------------

out_station = 0x1002
in_station  = 0x1001

IO.puts("Running #{cycles} cycles (#{period_ms} ms period) ...\n")

Enum.reduce(0..(cycles - 1), nil, fn step, last_inputs ->
  phase   = div(step, 50)
  on?     = rem(phase, 2) == 0
  out_val = if on?, do: 0xFF, else: 0x00

  case Master.cycle(%{out_station => <<out_val, out_val>>}) do
    {:ok, inputs} ->
      in_word =
        case Map.get(inputs, in_station) do
          <<w::16-little>> -> w
          _ -> 0
        end

      if in_word != last_inputs or rem(step, 50) == 0 do
        IO.puts(
          "step=#{String.pad_leading(to_string(step), 4)} " <>
            "out=#{if(on?, do: "ON ", else: "off")} " <>
            "inputs=0x#{String.pad_leading(Integer.to_string(in_word, 16), 4, "0")}"
        )
      end

      Process.sleep(period_ms)
      in_word

    {:error, reason} ->
      IO.puts("step=#{step} error: #{inspect(reason)}")
      Process.sleep(period_ms)
      last_inputs
  end
end)

IO.puts("\nDone.")
Master.stop()
