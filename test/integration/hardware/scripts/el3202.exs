#!/usr/bin/env elixir
# EL3202 — 2-channel PT100 RTD, resistance mode (1/16 Ω/bit)
#
# ## Hardware Requirements
#
# Required slaves:
#   - EK1100 coupler
#   - EL3202 two-channel PT100 RTD terminal
#
# Optional slaves:
#   - EL1809 and EL2809 are started in `process_data: :none` mode only to keep
#     the maintained bench topology intact; the script does not read or write
#     them
#
# Required capabilities:
#   - CoE mailbox access so the startup SDO configuration succeeds
#   - PDO input updates for `channel1` / `channel2`
#
# Starts EtherCAT with only the EL3202 driven.  Writes SDO config to set
# RTD element = ohm_1_16 (resistance mode, 1/16 Ω/bit), then prints per-channel
# readings using the named-PDO API (0x1A00 = channel1, 0x1A01 = channel2).
#
# Usage:
#   MIX_ENV=test mix run test/integration/hardware/scripts/el3202.exs --interface enp0s31f6
#
# Optional flags:
#   --channel 1|2|both    channel(s) to subscribe to   (default both)
#   --samples N           number of printed updates     (default 60)

alias EtherCAT.IntegrationSupport.Hardware

EtherCAT.TestSupport.RuntimeHelper.ensure_started!()

parse_channel = fn
  nil -> [:channel1, :channel2]
  "both" -> [:channel1, :channel2]
  "1" -> [:channel1]
  "2" -> [:channel2]
  other -> raise "channel must be 1, 2, or both, got: #{inspect(other)}"
end

{opts, _, _} =
  OptionParser.parse(System.argv(),
    switches: [interface: :string, channel: :string, samples: :integer]
  )

interface = opts[:interface] || raise "pass --interface"
channels = parse_channel.(opts[:channel])
samples = Keyword.get(opts, :samples, 60)

EtherCAT.stop()
Process.sleep(300)

EtherCAT.start(
  backend: {:raw, %{interface: interface}},
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
IO.puts("Running.")
IO.puts("Subscribed channels: #{Enum.map_join(channels, ", ", &Atom.to_string/1)}\n")

Enum.each(channels, fn channel ->
  EtherCAT.Raw.subscribe(:rtd, channel, self())
end)

Enum.each(1..samples, fn _ ->
  receive do
    {:ethercat, :signal, :rtd, ch, %{ohms: ohms} = data} when ch in [:channel1, :channel2] ->
      tag = if data.error, do: " ERR", else: if(data.invalid, do: " INVALID", else: "")
      IO.puts("#{ch}: #{:erlang.float_to_binary(ohms, decimals: 3)} Ω#{tag}")
  after
    500 -> IO.puts("(no data)")
  end
end)

EtherCAT.stop()
IO.puts("\nDone.")
