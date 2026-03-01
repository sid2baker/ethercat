#!/usr/bin/env elixir
# EtherCAT UDP transport test — spec §2.6
#
# Tests the UDP/IP encapsulation transport independently of the full master.
# ESCs that support UDP respond on port 0x88A4 (34980) regardless of source
# or destination IP — the only header field checked by the ESC is the UDP
# destination port.
#
# Three phases:
#   1. Raw socket diagnostic — send one minimal EtherCAT frame via :gen_udp
#      directly (no Bus layer) and wait for a response. Confirms basic network
#      reachability before testing the Bus API.
#   2. BRD stress — N transactions via Bus.start_link(transport: :udp) with
#      RTT statistics.
#   3. FPRD per slave — reads AL status from each auto-increment position to
#      count responding slaves, compared against BRD wkc.
#
# Usage:
#   mix run examples/udp_test.exs --interface eth0
#   mix run examples/udp_test.exs --interface eth0 --host 192.168.1.1
#   mix run examples/udp_test.exs --interface eth0 --count 200
#
# Flags:
#   --interface NIC  bind socket to this interface (required for correct NIC selection)
#   --host IP        unicast target (default: 255.255.255.255 broadcast)
#   --port N         UDP port (default: 34980 = 0x88A4)
#   --count N        BRD stress transaction count (default: 50)

alias EtherCAT.Bus
alias EtherCAT.Bus.{Command, Frame, Transaction}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

parse_ip = fn s ->
  case String.split(s, ".") |> Enum.map(&String.to_integer/1) do
    [a, b, c, d] -> {a, b, c, d}
    _ -> raise "invalid IP: #{s}"
  end
end

# Look up the first IPv4 address assigned to an interface.
# Returns nil if not found or interface has no IPv4 address.
interface_ipv4 = fn iface ->
  {:ok, ifaddrs} = :inet.getifaddrs()

  case List.keyfind(ifaddrs, String.to_charlist(iface), 0) do
    nil ->
      nil

    {_, attrs} ->
      attrs
      |> Keyword.get_values(:addr)
      |> Enum.find(&(tuple_size(&1) == 4))
  end
end

banner = fn title ->
  IO.puts("\n── #{title} " <> String.duplicate("─", max(0, 56 - String.length(title))))
end

fmt_us = fn us -> "#{us} µs" end

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

{opts, _, _} =
  OptionParser.parse(System.argv(),
    switches: [interface: :string, host: :string, port: :integer, count: :integer]
  )

iface = opts[:interface]
host  = if opts[:host], do: parse_ip.(opts[:host]), else: {255, 255, 255, 255}
port  = opts[:port] || 34980
count = opts[:count] || 50

# Resolve bind address: NIC's IPv4 if --interface given, otherwise wildcard
bind_ip =
  case iface do
    nil -> {0, 0, 0, 0}
    _   ->
      case interface_ipv4.(iface) do
        nil ->
          IO.puts("warning: #{iface} has no IPv4 address — binding to 0.0.0.0")
          {0, 0, 0, 0}
        ip -> ip
      end
  end

IO.puts("""
EtherCAT UDP transport test
  interface : #{iface || "(any)"}
  bind ip   : #{:inet.ntoa(bind_ip)}#{if bind_ip == {0,0,0,0}, do: "  (all interfaces)", else: ""}
  host      : #{:inet.ntoa(host)}#{if host == {255, 255, 255, 255}, do: "  (broadcast)", else: ""}
  port      : #{port} (0x#{Integer.to_string(port, 16)})
  count     : #{count} BRD transactions
""")

# ---------------------------------------------------------------------------
# Phase 1: Raw socket diagnostic
#
# Builds a minimal EtherCAT frame (BRD to reg 0x0000, 1 byte) directly using
# Bus.Frame and sends it via :gen_udp without going through the Bus gen_statem.
# This isolates socket-layer issues from the Bus state machine.
# Binding to the NIC's IP ensures packets egress on the correct interface.
# ---------------------------------------------------------------------------

banner.("1. Raw socket diagnostic")

sock_opts = [:binary, {:active, false}, {:broadcast, true}, {:ip, bind_ip}]

raw_ok =
  case :gen_udp.open(port, sock_opts) do
    {:ok, sock} ->
      IO.puts("  ✓ bound #{:inet.ntoa(bind_ip)}:#{port}")

      {:ok, ecat_payload} = Frame.encode([Command.brd(0, 1)])
      IO.puts("  ✓ frame built: #{byte_size(ecat_payload)} bytes  (EtherCAT header + BRD datagram)")

      t0 = System.monotonic_time(:nanosecond)
      :ok = :gen_udp.send(sock, host, port, ecat_payload)
      IO.puts("  ✓ sent to #{:inet.ntoa(host)}:#{port}")

      result =
        case :gen_udp.recv(sock, 0, 100) do
          {:ok, {src_ip, src_port, data}} ->
            rtt_us = div(System.monotonic_time(:nanosecond) - t0, 1000)
            IO.puts("  ✓ response from #{:inet.ntoa(src_ip)}:#{src_port}  " <>
                    "#{byte_size(data)} bytes  rtt=#{fmt_us.(rtt_us)}")

            case Frame.decode(data) do
              {:ok, dgs} ->
                IO.puts("  ✓ decoded #{length(dgs)} datagram(s)  wkc=#{hd(dgs).wkc}")
                :ok

              {:error, reason} ->
                IO.puts("  ✗ frame decode failed: #{inspect(reason)}")
                :error
            end

          {:error, :timeout} ->
            IO.puts("  ✗ no response within 100 ms")
            IO.puts("    → ESC may not support UDP (§2.6 optional), or port #{port} is blocked")
            :timeout

          {:error, reason} ->
            IO.puts("  ✗ recv error: #{inspect(reason)}")
            :error
        end

      :gen_udp.close(sock)
      result

    {:error, :eaddrinuse} ->
      IO.puts("  ✗ port #{port} already in use — stop other EtherCAT processes first")
      :error

    {:error, reason} ->
      IO.puts("  ✗ open failed: #{inspect(reason)}")
      :error
  end

if raw_ok == :timeout do
  IO.puts("""

  Stopping here — no UDP response from ESC. Possible causes:
    • ESC does not implement UDP/IP (§2.6 is optional; most EtherCOUPLERs don't)
    • Host firewall drops UDP port #{port}  →  check: iptables -L or ufw status
    • Packets went out the wrong NIC  →  pass --interface #{iface || "eth0"} to bind to the right one
    • Broadcast blocked on this subnet  →  try --host <esc_unicast_ip>
  """)
  System.halt(0)
end

# ---------------------------------------------------------------------------
# Phase 2: BRD stress via Bus API
# ---------------------------------------------------------------------------

banner.("2. BRD stress (#{count}×) via Bus.start_link")

bus_opts = [transport: :udp, host: host, port: port] ++
           if(bind_ip != {0, 0, 0, 0}, do: [bind_ip: bind_ip], else: [])

{:ok, bus} = Bus.start_link(bus_opts)
IO.puts("  ✓ bus open")

print_every = max(1, div(count, 10))

{ok_count, timeout_count, error_map, rtts} =
  Enum.reduce(1..count, {0, 0, %{}, []}, fn i, {ok, to, errs, rtts} ->
    t0 = System.monotonic_time(:nanosecond)
    result = Bus.transaction_queue(bus, &Transaction.brd(&1, {0x0000, 1}))
    rtt_us = div(System.monotonic_time(:nanosecond) - t0, 1000)

    if rem(i, print_every) == 0 do
      summary =
        case result do
          {:ok, [%{wkc: n}]} -> "wkc=#{n}  rtt=#{fmt_us.(rtt_us)}"
          {:error, r}        -> "#{inspect(r)}  rtt=#{fmt_us.(rtt_us)}"
        end

      IO.puts("  [#{String.pad_leading(to_string(i), String.length(to_string(count)))}] #{summary}")
    end

    case result do
      {:ok, [%{wkc: _}]} -> {ok + 1, to, errs, [rtt_us | rtts]}
      {:error, :timeout}  -> {ok, to + 1, errs, rtts}
      {:error, r}         -> {ok, to, Map.update(errs, r, 1, &(&1 + 1)), rtts}
    end
  end)

IO.puts("")
IO.puts("  ok      : #{ok_count}/#{count}")
IO.puts("  timeout : #{timeout_count}/#{count}")
if map_size(error_map) > 0, do: IO.puts("  errors  : #{inspect(error_map)}")

if length(rtts) > 0 do
  sorted = Enum.sort(rtts)
  n = length(sorted)
  p99_idx = min(n - 1, round(n * 0.99) - 1)
  IO.puts("  rtt min : #{fmt_us.(List.first(sorted))}")
  IO.puts("  rtt avg : #{fmt_us.(div(Enum.sum(sorted), n))}")
  IO.puts("  rtt p99 : #{fmt_us.(Enum.at(sorted, p99_idx))}")
  IO.puts("  rtt max : #{fmt_us.(List.last(sorted))}")
end

brd_wkc =
  case Bus.transaction_queue(bus, &Transaction.brd(&1, {0x0000, 1})) do
    {:ok, [%{wkc: n}]} -> n
    _ -> nil
  end

# ---------------------------------------------------------------------------
# Phase 3: FPRD per slave — compare slave count with BRD wkc
# ---------------------------------------------------------------------------

if brd_wkc && brd_wkc > 0 do
  banner.("3. FPRD AL status  (#{brd_wkc} slave(s) expected from BRD)")

  responding =
    Enum.filter(0..(brd_wkc + 1), fn pos ->
      case Bus.transaction_queue(bus, &Transaction.aprd(&1, pos, {0x0130, 2})) do
        {:ok, [%{wkc: 1, data: <<al::16-little>>}]} ->
          state = case Bitwise.band(al, 0xF) do
            1 -> :init
            2 -> :preop
            4 -> :safeop
            8 -> :op
            n -> :"unknown(#{n})"
          end
          error = Bitwise.band(al, 0x10) != 0
          IO.puts("  pos #{pos}: AL=#{state}#{if error, do: " ERR", else: ""}")
          true

        {:ok, [%{wkc: 0}]} ->
          false

        {:error, reason} ->
          IO.puts("  pos #{pos}: #{inspect(reason)}")
          false
      end
    end)

  IO.puts("")
  IO.puts("  responding slaves : #{length(responding)}  (BRD wkc=#{brd_wkc})")

  if length(responding) != brd_wkc do
    IO.puts("  ! count mismatch — some slaves may not support APRD")
  end
end

GenServer.stop(bus)

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

IO.puts("")

verdict =
  cond do
    ok_count == count -> "PASS ✓  (#{count}/#{count})"
    ok_count > 0      -> "PARTIAL  (#{ok_count}/#{count} succeeded)"
    true              -> "FAIL ✗   (0/#{count})"
  end

IO.puts("Verdict: #{verdict}")
IO.puts("")
