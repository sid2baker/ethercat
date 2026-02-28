#!/usr/bin/env elixir
# EL3202 — 2-channel PT100 RTD, resistance mode (1/16 Ω/bit)
#
# Starts EtherCAT with only the EL3202 driven.  Writes SDO config to set
# RTD element = ohm_1_16 (resistance mode, 1/16 Ω/bit), then prints per-channel
# readings using the named-PDO API (0x1A00 = channel1, 0x1A01 = channel2).
#
# Usage:
#   mix run examples/el3202.exs --interface enp0s31f6

defmodule El3202Driver do
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile(_config) do
    # Two 32-bit TxPDOs on SM3; master derives SM, size, and bit offsets from SII.
    %{channel1: 0x1A00, channel2: 0x1A01}
  end

  @impl true
  def sdo_config(_config) do
    [
      # RTD element (0x80n0:0x19) controls the measurement mode:
      #   0=PT100  1=Ni100  2=PT1000 ... 8=ohm_1_16  9=ohm_1_64
      # Resistance output (1/16 Ω/bit, 0–4096 Ω range) = element 8.
      {0x8000, 0x19, 8, 2},  # ch1 RTD element = ohm_1_16
      {0x8010, 0x19, 8, 2}   # ch2 RTD element = ohm_1_16
    ]
  end

  @impl true
  def encode_outputs(_pdo, _config, _), do: <<>>

  @impl true
  # Each PDO is 4 bytes:
  #   byte 0 — [gap(1), error(1), limit2(2), limit1(2), overrange(1), underrange(1)]
  #   byte 1 — [toggle(1), state(1), gap(6)]
  #   bytes 2–3 — UINT16 LE resistance (1/16 Ω/bit, unsigned in resistance mode)
  def decode_inputs(:channel1, _config, <<
        _::1, error::1, _limit2::2, _limit1::2, overrange::1, underrange::1,
        toggle::1, state::1, _::6, value::16-little>>) do
    %{ohms: value / 16.0, overrange: overrange == 1, underrange: underrange == 1,
      error: error == 1, invalid: state == 1, toggle: toggle}
  end
  def decode_inputs(:channel2, _config, <<
        _::1, error::1, _limit2::2, _limit1::2, overrange::1, underrange::1,
        toggle::1, state::1, _::6, value::16-little>>) do
    %{ohms: value / 16.0, overrange: overrange == 1, underrange: underrange == 1,
      error: error == 1, invalid: state == 1, toggle: toggle}
  end
  def decode_inputs(_pdo, _config, _), do: nil
end

{opts, _, _} = OptionParser.parse(System.argv(), switches: [interface: :string])
interface = opts[:interface] || raise "pass --interface"

EtherCAT.stop()
Process.sleep(300)

EtherCAT.start(
  interface: interface,
  domains: [[id: :main, period: 10]],
  slaves: [
    nil,
    nil,
    nil,
    [name: :thermo, driver: El3202Driver, config: %{}, pdos: [channel1: :main, channel2: :main]]
  ]
)

IO.puts("Waiting for OP...")
:ok = EtherCAT.await_running(10_000)
IO.puts("Running.\n")

EtherCAT.subscribe(:thermo, :channel1, self())
EtherCAT.subscribe(:thermo, :channel2, self())

Enum.each(1..60, fn _ ->
  receive do
    {:slave_input, :thermo, ch, %{ohms: ohms} = data} ->
      tag = if data.error, do: " ERR", else: if(data.invalid, do: " INVALID", else: "")
      IO.puts("#{ch}: #{:erlang.float_to_binary(ohms, decimals: 3)} Ω#{tag}")
  after
    500 -> IO.puts("(no data)")
  end
end)

EtherCAT.stop()
IO.puts("\nDone.")
