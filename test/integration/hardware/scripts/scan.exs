# Scan the EtherCAT bus: count slaves, assign stations, read SII identity.
#
# ## Hardware Requirements
#
# Required hardware:
#   - one powered EtherCAT segment on the selected interface
#
# Required capabilities:
#   - broadcast read/write access to assign temporary station addresses
#   - SII identity reads on the discovered slaves
#   - no other master process should be assigning stations concurrently
#
# Usage:
#   MIX_ENV=test mix run test/integration/hardware/scripts/scan.exs --interface enp0s31f6

alias EtherCAT.Bus
alias EtherCAT.Bus.Transaction
alias EtherCAT.Slave.ESC.{Registers, SII}

{opts, _, _} = OptionParser.parse(System.argv(), switches: [interface: :string])
interface = opts[:interface] || raise "pass --interface, e.g. --interface enp0s31f6"

{:ok, bus} = Bus.start_link(interface: interface)

{:ok, [%{wkc: count}]} = Bus.transaction(bus, Transaction.brd({0x0000, 1}))
IO.puts("#{count} slave(s) on #{interface}\n")

Enum.each(0..(count - 1), fn pos ->
  station = 0x1000 + pos
  Bus.transaction(bus, Transaction.apwr(pos, Registers.station_address(station)))
end)

Enum.each(0..(count - 1), fn pos ->
  station = 0x1000 + pos
  hex = &("0x" <> String.upcase(Integer.to_string(&1, 16)))

  case SII.read_identity(bus, station) do
    {:ok, id} ->
      IO.puts(
        "  [#{pos}] #{hex.(station)}  vendor=#{hex.(id.vendor_id)}  product=#{hex.(id.product_code)}  rev=#{hex.(id.revision)}  sn=#{id.serial_number}"
      )

    {:error, reason} ->
      IO.puts("  [#{pos}] #{hex.(station)}  error: #{inspect(reason)}")
  end
end)

:gen_statem.stop(bus)
