#!/usr/bin/env elixir
# EL3202 — 2-channel PT100 RTD, resistance mode (1/16 Ω/bit)
#
# Starts EtherCAT with only the EL3202 driven.  Writes SDO config to set
# RTD element = ohm_1_16 (resistance mode, 1/16 Ω/bit), then prints per-channel
# readings using the named-PDO API (0x1A00 = channel1, 0x1A01 = channel2).
#
# Usage:
#   MIX_ENV=test mix run test/integration/hardware/scripts/el3202.exs --interface enp0s31f6

alias EtherCAT.IntegrationSupport.Hardware

{opts, _, _} = OptionParser.parse(System.argv(), switches: [interface: :string])
interface = opts[:interface] || raise "pass --interface"

EtherCAT.stop()
Process.sleep(300)

EtherCAT.start(
  interface: interface,
  domains: [Hardware.main_domain()],
  slaves: [
    Hardware.coupler(),
    Hardware.inputs(process_data: :none),
    Hardware.outputs(process_data: :none),
    Hardware.rtd(process_data: [channel1: :main, channel2: :main])
  ]
)

IO.puts("Waiting for OP...")
:ok = EtherCAT.await_running(10_000)
IO.puts("Running.\n")

EtherCAT.subscribe(:rtd, :channel1, self())
EtherCAT.subscribe(:rtd, :channel2, self())

Enum.each(1..60, fn _ ->
  receive do
    {:ethercat, :signal, :rtd, ch, %{ohms: ohms} = data} ->
      tag = if data.error, do: " ERR", else: if(data.invalid, do: " INVALID", else: "")
      IO.puts("#{ch}: #{:erlang.float_to_binary(ohms, decimals: 3)} Ω#{tag}")
  after
    500 -> IO.puts("(no data)")
  end
end)

EtherCAT.stop()
IO.puts("\nDone.")
