#!/usr/bin/env elixir
# Mailbox / SDO diagnostic for the EL3202 CoE slave.
#
# Reads SII mailbox config + ESC SM register state, then tests
# whether writing a full recv_size-padded SDO frame makes SM1 go "full"
# (i.e., the slave actually processed the request and put a response in SM1).
#
# Usage:
#   mix run examples/sdo_debug.exs --interface enp0s31f6

alias EtherCAT.Link
alias EtherCAT.Link.Transaction
alias EtherCAT.Slave.{Registers, SII}

{opts, _, _} = OptionParser.parse(System.argv(), switches: [interface: :string])
interface = opts[:interface] || raise "pass --interface"

EtherCAT.stop()
Process.sleep(300)

# Minimal start: no domains, no PDOs — we just need the link and PREOP
EtherCAT.start(
  interface: interface,
  domains: [],
  slaves: [nil, nil, nil, [name: :thermo, driver: nil, config: %{}, pdos: []]]
)

# Allow auto-advance (SII read + mailbox SM setup + PREOP transition) to complete
Process.sleep(4000)

link = EtherCAT.link()
[{:thermo, station, _}] = EtherCAT.slaves()

IO.puts("station: 0x#{Integer.to_string(station, 16)}\n")

# ── 1. SII mailbox config ────────────────────────────────────────────────────

{:ok, mbx} = SII.read_mailbox_config(link, station)
IO.puts("SII mailbox recv : offset=0x#{Integer.to_string(mbx.recv_offset, 16)}  size=#{mbx.recv_size}")
IO.puts("SII mailbox send : offset=0x#{Integer.to_string(mbx.send_offset, 16)}  size=#{mbx.send_size}")

# ── 2. SM register state ─────────────────────────────────────────────────────

for i <- 0..1 do
  {:ok, [%{data: <<phys::16-little, len::16-little, ctrl::8, _::8, act::8, _::8>>, wkc: wkc}]} =
    Link.transaction(link, &Transaction.fprd(&1, station, {Registers.sm(i), 8}))
  IO.puts("SM#{i} : phys=0x#{Integer.to_string(phys, 16)}  len=#{len}  ctrl=0x#{Integer.to_string(ctrl, 16)}  activate=#{act}  wkc=#{wkc}")
end

# ── 3. SM1 status before any write ───────────────────────────────────────────

{:ok, [%{data: <<st::8>>, wkc: wkc}]} =
  Link.transaction(link, &Transaction.fprd(&1, station, Registers.sm_status(1)))
IO.puts("\nSM1 status before write : 0x#{Integer.to_string(st, 16)}  bit3(full)=#{Bitwise.band(st, 0x08) != 0}  wkc=#{wkc}")

# ── 4. Build SDO frame: write 0x8000:0x02 = 4 (Presentation = 1/64 Ω) ──────

# Mailbox header (6 B): length=10, address=0, channel=0, priority=0, type=CoE(3)
# CoE header    (2 B): number=0, service=2 (SDO request)
# SDO body      (8 B): cmd=0x2F (1-byte expedited), index, subindex, value
frame = <<10::16-little, 0::16, 0::8, 0x03::8,
          0x00, 0x20,
          0x2F::8, 0x8000::16-little, 0x02::8, 4::32-little>>

frame_size = byte_size(frame)
IO.puts("\nSDO frame size : #{frame_size} bytes  recv_size : #{mbx.recv_size} bytes")

# ── 5. Test A — unpadded write (current coe.ex behaviour) ────────────────────

IO.puts("\n[A] Unpadded write (#{frame_size} bytes):")
{:ok, [%{wkc: wkc_a}]} =
  Link.transaction(link, &Transaction.fpwr(&1, station, {mbx.recv_offset, frame}))
IO.puts("    write wkc=#{wkc_a}")

Process.sleep(300)
{:ok, [%{data: <<st_a::8>>}]} =
  Link.transaction(link, &Transaction.fprd(&1, station, Registers.sm_status(1)))
IO.puts("    SM1 status : 0x#{Integer.to_string(st_a, 16)}  bit3=#{Bitwise.band(st_a, 0x08) != 0}")

# ── 6. Reset SM0 by rewriting its register, then test B ──────────────────────

# Rewrite SM0 so it returns to the "writeable" initial mailbox state
sm0_reset = <<mbx.recv_offset::16-little, mbx.recv_size::16-little, 0x26::8, 0::8, 0x01::8, 0::8>>
Link.transaction(link, &Transaction.fpwr(&1, station, Registers.sm(0, sm0_reset)))
Process.sleep(50)

IO.puts("\n[B] Padded write (#{mbx.recv_size} bytes — frame + zeros):")
padded = frame <> :binary.copy(<<0>>, mbx.recv_size - frame_size)
{:ok, [%{wkc: wkc_b}]} =
  Link.transaction(link, &Transaction.fpwr(&1, station, {mbx.recv_offset, padded}))
IO.puts("    write wkc=#{wkc_b}")

for i <- 1..20 do
  Process.sleep(50)
  {:ok, [%{data: <<st::8>>}]} =
    Link.transaction(link, &Transaction.fprd(&1, station, Registers.sm_status(1)))
  full = Bitwise.band(st, 0x08) != 0
  IO.puts("    poll #{String.pad_leading(to_string(i), 2)} : SM1 status=0x#{Integer.to_string(st, 16)}  bit3=#{full}#{if full, do: "  ← FULL", else: ""}")
end

EtherCAT.stop()
IO.puts("\nDone.")
