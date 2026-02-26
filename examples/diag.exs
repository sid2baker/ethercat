# Diagnose: is the frame getting sent and response received at all?
# Usage: mix run examples/diag.exs --interface enp0s31f6
alias EtherCAT.Link
alias EtherCAT.Link.{Command, Frame, Socket}

{opts, _, _} = OptionParser.parse(System.argv(), switches: [interface: :string])
interface = opts[:interface] || raise "pass --interface"

IO.puts("1. Opening socket on #{interface}...")
{:ok, sock} = Socket.open(interface)
IO.puts("   OK: #{inspect(sock)}")

# Build a BRD frame
dg = Command.brd(0x0000, 1)
IO.puts("2. Datagram: #{inspect(dg)}")
{:ok, frame} = Frame.encode([dg], sock.src_mac)
IO.puts("3. Frame (#{byte_size(frame)} bytes): #{Base.encode16(frame)}")

# Send
IO.puts("4. Sending via sendto...")
{:ok, tx_at} = Socket.send(sock, frame)
IO.puts("   sent at: #{tx_at}")

# Receive loop — try up to 10 packets over 3s
IO.puts("5. Receiving (up to 10 packets, 3s total)...")
deadline = System.monotonic_time(:millisecond) + 3000

Enum.reduce_while(1..10, nil, fn i, _acc ->
  remaining = max(deadline - System.monotonic_time(:millisecond), 1)

  case :socket.recvmsg(sock.raw, 0, 0, remaining) do
    {:ok, msg} ->
      data =
        case msg do
          %{iov: [d | _]} -> d
          _ -> <<>>
        end

      # Check the sockaddr for packet direction (outgoing vs incoming)
      addr_info = Map.get(msg, :addr, %{})
      IO.puts("   pkt #{i}: #{byte_size(data)} bytes, addr=#{inspect(addr_info, limit: 100)}")
      IO.puts("          first 30 bytes: #{Base.encode16(binary_part(data, 0, min(30, byte_size(data))))}")

      case Frame.decode(data) do
        {:ok, datagrams, src_mac} ->
          IO.puts("          EtherCAT frame! src=#{Base.encode16(src_mac)} datagrams=#{inspect(datagrams, limit: 200)}")
          {:cont, nil}

        {:error, reason} ->
          IO.puts("          not EtherCAT: #{reason}")
          {:cont, nil}
      end

    {:error, :timeout} ->
      IO.puts("   pkt #{i}: timeout (no more packets)")
      {:halt, nil}

    {:error, reason} ->
      IO.puts("   pkt #{i}: error #{inspect(reason)}")
      {:halt, nil}
  end
end)

Socket.close(sock)
