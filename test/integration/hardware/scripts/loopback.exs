#!/usr/bin/env elixir
# Inspect the actual SII PDO configs and LRW frame data for EL2809.
#
# ## Hardware Requirements
#
# Required slaves:
#   - EK1100 coupler
#   - EL2809 digital output terminal at station `0x1002`
#
# Optional slaves:
#   - EL1809 and EL3202 are started only to preserve the maintained bench
#     layout; they are not part of the core inspection logic
#
# Required capabilities:
#   - direct EtherCAT bus access for raw SII and FPRD reads
#   - one writable EL2809 PDO mapped into a domain
#
# Adaptation notes:
#   - this script intentionally assumes the maintained bench station order and
#     reads the EL2809 directly at station `0x1002`; change those station
#     addresses first if your coupler layout differs
#   - the domain start uses a synthetic slave name `:out`; if your bench needs a
#     different name, update both the `Hardware.outputs(name: :out, ...)` call
#     and the later `DomainAPI.read(:main, {:out, ...})` lookup together

alias EtherCAT.{Bus, Domain}
alias EtherCAT.Domain, as: DomainAPI
alias EtherCAT.Bus.Transaction
alias EtherCAT.Slave.ESC.{Registers, SII}
alias EtherCAT.IntegrationSupport.Hardware

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

:gen_statem.stop(link)
Process.sleep(300)

# --- Step 2: start master and inspect domain frame ---
IO.puts("\n=== Domain frame when ch1=1 ===")
EtherCAT.stop()
Process.sleep(300)

:ok =
  EtherCAT.start(
    interface: interface,
    domains: [Hardware.main_domain(cycle_time_us: 4_000)],
    slaves: [
      Hardware.coupler(),
      Hardware.inputs(process_data: :none),
      Hardware.outputs(name: :out, process_data: [ch1: :main]),
      Hardware.rtd(process_data: :none, target_state: :preop)
    ]
  )

:ok = EtherCAT.await_operational(10_000)

{:ok, bus} = EtherCAT.Diagnostics.bus()

# Read domain stats to know image size
{:ok, stats} = DomainAPI.stats(:main)
IO.puts("image_size=#{stats.image_size}")

# Read current output ETS value and SM0 before any write_output
sm0_before =
  case Bus.transaction(bus, Transaction.fprd(0x1002, {0x0F00, 2})) do
    {:ok, [%{data: d, wkc: w}]} when w > 0 -> inspect(d, base: :hex)
    _ -> "err"
  end

IO.puts("EL2809 SM0+SM1 before write_output: #{sm0_before}")

EtherCAT.Raw.write_output(:out, :ch1, 1)
Process.sleep(20)

# ETS holds the raw encoded value the domain will splice into the frame
ets_val = DomainAPI.read(:main, {:out, :ch1})
IO.puts("ETS {:out,:ch1} = #{inspect(ets_val)}")

sm0_after =
  case Bus.transaction(bus, Transaction.fprd(0x1002, {0x0F00, 2})) do
    {:ok, [%{data: d, wkc: w}]} when w > 0 -> inspect(d, base: :hex)
    _ -> "err"
  end

IO.puts("EL2809 SM0+SM1 after  write_output: #{sm0_after}")

EtherCAT.stop()
IO.puts("Done.")
