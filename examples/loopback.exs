#!/usr/bin/env elixir
# Inspect the actual SII PDO configs and LRW frame data for EL2809.

alias EtherCAT.{Domain, Bus}
alias EtherCAT.Bus.Transaction
alias EtherCAT.Slave.{Config, Registers, SII}
alias EtherCAT.Domain.Config, as: DomainConfig

defmodule DigitalOut do
  @behaviour EtherCAT.Slave.Driver
  def process_data_model(_), do: %{ch1: 0x1600}
  def encode_signal(_, _, v), do: <<v::8>>
  def decode_signal(_, _, _), do: nil
end

{opts, _, _} = OptionParser.parse(System.argv(), switches: [interface: :string])
interface = opts[:interface] || raise "pass --interface"

# --- Step 1: read SII PDO configs directly (no master running) ---
IO.puts("=== SII PDO configs for EL2809 (station 0x1002) ===")
{:ok, link} = Bus.start_link(interface: interface)

# Assign station addresses
for pos <- 0..3 do
  Bus.transaction(link, Transaction.apwr(pos, Registers.station_address(0x1000 + pos)))
end

case SII.read_pdo_configs(link, 0x1002) do
  {:ok, pdos} ->
    IO.puts("#{length(pdos)} PDOs found:\n")

    for p <- pdos do
      IO.puts(
        "  0x#{Integer.to_string(p.index, 16)}  dir=#{p.direction}  sm=#{p.sm_index}  " <>
          "bit_size=#{p.bit_size}  bit_offset=#{p.bit_offset}"
      )
    end

  {:error, e} ->
    IO.puts("error: #{inspect(e)}")
end

Process.exit(link, :kill)
Process.sleep(300)

# --- Step 2: start master and inspect domain frame ---
IO.puts("\n=== Domain frame when ch1=1 ===")
EtherCAT.stop()
Process.sleep(300)

:ok =
  EtherCAT.start(
    interface: interface,
    domains: [%DomainConfig{id: :main, cycle_time_us: 4_000}],
    slaves: [
      %Config{name: :coupler},
      %Config{name: :bridge_1},
      %Config{name: :out, driver: DigitalOut, process_data: [ch1: :main]},
      %Config{name: :bridge_3}
    ]
  )

:ok = EtherCAT.await_operational(10_000)

bus = EtherCAT.bus()

# Read domain stats to know image size
{:ok, stats} = Domain.stats(:main)
IO.puts("image_size=#{stats.image_size}")

# Read current output ETS value and SM0 before any write_output
sm0_before =
  case Bus.transaction(bus, Transaction.fprd(0x1002, {0x0F00, 2})) do
    {:ok, [%{data: d, wkc: w}]} when w > 0 -> inspect(d, base: :hex)
    _ -> "err"
  end

IO.puts("EL2809 SM0+SM1 before write_output: #{sm0_before}")

EtherCAT.write_output(:out, :ch1, 1)
Process.sleep(20)

# ETS holds the raw encoded value the domain will splice into the frame
ets_val = Domain.read(:main, {:out, :ch1})
IO.puts("ETS {:out,:ch1} = #{inspect(ets_val)}")

sm0_after =
  case Bus.transaction(bus, Transaction.fprd(0x1002, {0x0F00, 2})) do
    {:ok, [%{data: d, wkc: w}]} when w > 0 -> inspect(d, base: :hex)
    _ -> "err"
  end

IO.puts("EL2809 SM0+SM1 after  write_output: #{sm0_after}")

EtherCAT.stop()
IO.puts("Done.")
