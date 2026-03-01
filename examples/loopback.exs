#!/usr/bin/env elixir
# Inspect the actual SII PDO configs and LRW frame data for EL2809.

alias EtherCAT.{Domain, Bus}
alias EtherCAT.Bus.Transaction
alias EtherCAT.Slave.SII

defmodule DigitalOut do
  @behaviour EtherCAT.Slave.Driver
  def process_data_profile(_), do: %{ch1: 0x1600}
  def encode_outputs(_, _, v), do: <<v::8>>
  def decode_inputs(_, _, _), do: nil
end

{opts, _, _} = OptionParser.parse(System.argv(), switches: [interface: :string])
interface = opts[:interface] || raise "pass --interface"

# --- Step 1: read SII PDO configs directly (no master running) ---
IO.puts("=== SII PDO configs for EL2809 (station 0x1002) ===")
{:ok, link} = Bus.start_link(interface: interface)

# Assign station addresses
for pos <- 0..3 do
  Bus.transaction_queue(link, &Transaction.apwr(&1, pos, {0x0010, <<(0x1000 + pos)::16-little>>}))
end

case SII.read_pdo_configs(link, 0x1002) do
  {:ok, pdos} ->
    IO.puts("#{length(pdos)} PDOs found:\n")
    for p <- pdos do
      IO.puts("  0x#{Integer.to_string(p.index, 16)}  dir=#{p.direction}  sm=#{p.sm_index}  " <>
              "bit_size=#{p.bit_size}  bit_offset=#{p.bit_offset}")
    end
  {:error, e} -> IO.puts("error: #{inspect(e)}")
end

Process.exit(link, :kill)
Process.sleep(300)

# --- Step 2: start master and inspect domain frame ---
IO.puts("\n=== Domain frame when ch1=1 ===")
EtherCAT.stop()
Process.sleep(300)

:ok = EtherCAT.start(
  interface: interface,
  domains: [[id: :main, period: 4]],
  slaves: [nil, nil, [name: :out, driver: DigitalOut, config: %{}, pdos: [ch1: :main]], nil]
)
:ok = EtherCAT.await_running(10_000)

link2 = EtherCAT.link()

# Read domain stats to know image size
{:ok, stats} = Domain.stats(:main)
IO.puts("image_size=#{stats.image_size}")

# Read current output ETS value and SM0 before any set_output
sm0_before = case Bus.transaction_queue(link2, &Transaction.fprd(&1, 0x1002, {0x0F00, 2})) do
  {:ok, [%{data: d, wkc: w}]} when w > 0 -> inspect(d, base: :hex)
  _ -> "err"
end
IO.puts("EL2809 SM0+SM1 before set_output: #{sm0_before}")

EtherCAT.set_output(:out, :ch1, 1)
Process.sleep(20)

# ETS holds the raw encoded value the domain will splice into the frame
ets_val = Domain.read(:main, {:out, :ch1})
IO.puts("ETS {:out,:ch1} = #{inspect(ets_val)}")

sm0_after = case Bus.transaction_queue(link2, &Transaction.fprd(&1, 0x1002, {0x0F00, 2})) do
  {:ok, [%{data: d, wkc: w}]} when w > 0 -> inspect(d, base: :hex)
  _ -> "err"
end
IO.puts("EL2809 SM0+SM1 after  set_output: #{sm0_after}")

EtherCAT.stop()
IO.puts("Done.")
