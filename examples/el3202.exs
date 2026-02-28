#!/usr/bin/env elixir
# EL3202 — 2-channel PT100 RTD, resistance mode (1/64 Ω/bit)
#
# Starts EtherCAT with only the EL3202 driven.  Writes SDO config to set
# Presentation = 1/64 Ω and RTD element = PT100, then prints readings.
#
# Usage:
#   mix run examples/el3202.exs --interface enp0s31f6

defmodule El3202Driver do
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile(_config) do
    # SM3 = TxPDO; physical address and size read from SII EEPROM
    %{data: %{sm_index: 3}}
  end

  @impl true
  def sdo_config(_config) do
    [
      # RTD element (0x80n0:0x19) controls the measurement mode:
      #   0=PT100  1=Ni100  2=PT1000 ... 8=ohm_1_16  9=ohm_1_64
      # Resistance output (1/16 Ω/bit, 0–4096 Ω range) = element 8.
      {0x8000, 0x19, 8, 2},  # ch1 RTD element = ohm_1_16
      {0x8010, 0x19, 8, 2}   # ch2 RTD element = ohm_1_16
      # Presentation (0x80n0:0x02) only changes sign representation (0=signed default).
      # Leave at default — it does NOT select resistance vs temperature mode.
    ]
  end

  @impl true
  def encode_outputs(_pdo, _config, _), do: <<>>

  @impl true
  # 4 bytes per channel:
  #   byte 0 — [gap(1), error(1), limit2(2), limit1(2), overrange(1), underrange(1)]
  #   byte 1 — [toggle(1), state(1), gap(6)]
  #   bytes 2–3 — UINT16 LE resistance (1/16 Ω/bit, unsigned in resistance mode)
  def decode_inputs(:data, _config, <<
        _::1, error1::1, _limit2_1::2, _limit1_1::2, overrange1::1, underrange1::1,
        toggle1::1, state1::1, _::6, ch1::16-little,
        _::1, error2::1, _limit2_2::2, _limit1_2::2, overrange2::1, underrange2::1,
        toggle2::1, state2::1, _::6, ch2::16-little>>) do
    {
      %{ohms: ch1 / 16.0, overrange: overrange1 == 1, underrange: underrange1 == 1,
        error: error1 == 1, invalid: state1 == 1, toggle: toggle1},
      %{ohms: ch2 / 16.0, overrange: overrange2 == 1, underrange: underrange2 == 1,
        error: error2 == 1, invalid: state2 == 1, toggle: toggle2}
    }
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
    [name: :thermo, driver: El3202Driver, config: %{}, pdos: [data: :main]]
  ]
)

IO.puts("Waiting for OP...")
:ok = EtherCAT.await_running(10_000)
IO.puts("Running.\n")

EtherCAT.subscribe(:thermo, :data, self())

Enum.each(1..30, fn _ ->
  receive do
    {:slave_input, :thermo, :data, {ch1, ch2}} ->
      tag1 = if(ch1.error, do: " ERR", else: if(ch1.invalid, do: " INVALID", else: ""))
      tag2 = if(ch2.error, do: " ERR", else: if(ch2.invalid, do: " INVALID", else: ""))
      IO.puts("ch1: #{:erlang.float_to_binary(ch1.ohms, decimals: 3)} Ω#{tag1}   " <>
              "ch2: #{:erlang.float_to_binary(ch2.ohms, decimals: 3)} Ω#{tag2}")
  after
    500 -> IO.puts("(no data)")
  end
end)

EtherCAT.stop()
IO.puts("\nDone.")
