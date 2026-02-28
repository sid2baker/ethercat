# Raw socket probe — bypasses EtherCAT.Link entirely.
#
# Opens an AF_PACKET socket directly and sends a minimal EtherCAT BRD frame,
# polling for the response with :socket.recvmsg. Shows every step so you can
# see exactly where frames are lost.
#
# Usage in IEx:
#   import_file("examples/probe.exs")
#   Probe.run("eth0")
#   Probe.run("eth0", frames: 20, timeout_ms: 500)

defmodule Probe do
  @af_packet 17
  @ethertype 0x88A4
  @broadcast_mac <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>

  def run(interface, opts \\ []) do
    frames    = Keyword.get(opts, :frames, 20)
    timeout_ms = Keyword.get(opts, :timeout_ms, 200)

    IO.puts("\nRaw socket probe — #{interface}, #{frames} frames, #{timeout_ms}ms timeout")
    IO.puts(String.duplicate("-", 60))

    # --- interface info -------------------------------------------------------
    lower_up = VintageNet.get(["interface", interface, "lower_up"])
    mac_str  = VintageNet.get(["interface", interface, "mac_address"])
    IO.puts("  lower_up : #{inspect(lower_up)}")
    IO.puts("  mac      : #{inspect(mac_str)}")

    unless lower_up == true do
      IO.puts("  WARNING: interface is not carrier-up — frames will not return")
    end

    # --- open socket ----------------------------------------------------------
    {:ok, idx} = :net.if_name2index(String.to_charlist(interface))
    src_mac = decode_mac(mac_str)

    {:ok, sock} = :socket.open(@af_packet, :raw, {:raw, @ethertype})
    :ok = :socket.bind(sock, sockaddr_ll(idx))
    IO.puts("  ifindex  : #{idx}")
    IO.puts("  socket   : open\n")

    # Drain any stale frames already in the buffer before we start
    stale = drain(sock, 0)
    if stale > 0, do: IO.puts("  drained #{stale} stale frame(s) from buffer\n")

    # --- send frames ----------------------------------------------------------
    results =
      Enum.map(1..frames, fn i ->
        frame = build_brd_frame(src_mac, i)
        dest  = sockaddr_ll(idx, @broadcast_mac)

        t0 = System.monotonic_time(:microsecond)
        :ok = :socket.sendto(sock, frame, dest)

        case poll_recv(sock, timeout_ms) do
          {:ok, _data, t1} ->
            rtt = t1 - t0
            IO.puts("  frame #{String.pad_leading(to_string(i), 3)}: ok  #{rtt} µs")
            {:ok, rtt}

          :timeout ->
            IO.puts("  frame #{String.pad_leading(to_string(i), 3)}: TIMEOUT (#{timeout_ms} ms)")
            :timeout
        end
      end)

    :socket.close(sock)

    ok  = Enum.count(results, &match?({:ok, _}, &1))
    err = Enum.count(results, &(&1 == :timeout))
    rtts = for {:ok, r} <- results, do: r

    IO.puts("\n  ok/timeout : #{ok}/#{err}")
    if rtts != [] do
      sorted = Enum.sort(rtts)
      IO.puts("  min RTT    : #{List.first(sorted)} µs")
      IO.puts("  avg RTT    : #{div(Enum.sum(sorted), length(sorted))} µs")
      IO.puts("  max RTT    : #{List.last(sorted)} µs")
    end
    :ok
  end

  # Poll with recvmsg until data arrives or timeout. Cancels the select on
  # timeout so the next call gets a clean socket state.
  defp poll_recv(sock, timeout_ms) do
    case :socket.recvmsg(sock, 0, 0, :nowait) do
      {:ok, msg} ->
        {:ok, iov_data(msg), System.monotonic_time(:microsecond)}

      {:select, select_info} ->
        {:select_info, _, ref} = select_info
        receive do
          {:"$socket", ^sock, :select, ^ref} ->
            case :socket.recvmsg(sock, 0, 0, :nowait) do
              {:ok, msg} -> {:ok, iov_data(msg), System.monotonic_time(:microsecond)}
              _ -> :timeout
            end
        after
          timeout_ms ->
            :socket.cancel(sock, select_info)
            :timeout
        end

      _ ->
        :timeout
    end
  end

  # Drain all buffered frames. Cancels the final pending select so the socket
  # is clean before the first send.
  defp drain(sock, count) do
    case :socket.recvmsg(sock, 0, 0, :nowait) do
      {:ok, _} ->
        drain(sock, count + 1)

      {:select, select_info} ->
        :socket.cancel(sock, select_info)
        count

      _ ->
        count
    end
  end

  # Minimal EtherCAT frame: one BRD datagram reading 1 byte at offset 0.
  # idx byte used as datagram index for identification.
  defp build_brd_frame(src_mac, idx) do
    # EtherCAT datagram: cmd=7(BRD), idx, addr_lo=0, addr_hi=0, len=1, irq=0, data=0, wkc=0
    <<byte_idx>> = <<idx::8>>
    datagram = <<7, byte_idx, 0::16, 0::16, 1::11, 0::3, 0::1, 0::1, 0::16, 0::8, 0::16>>
    # EtherCAT header: length = datagram size, type=1
    ec_len = byte_size(datagram)
    ec_header = <<ec_len::11, 0::1, 1::4>>
    payload = ec_header <> datagram
    # Ethernet header
    @broadcast_mac <> src_mac <> <<@ethertype::16>> <> payload
  end

  defp decode_mac(nil), do: <<0, 0, 0, 0, 0, 0>>
  defp decode_mac(s) do
    s |> String.split(":") |> Enum.map(&String.to_integer(&1, 16)) |> :binary.list_to_bin()
  end

  defp sockaddr_ll(ifindex, mac \\ <<0::48>>) do
    mac_padded = if byte_size(mac) < 8, do: mac <> <<0::16>>, else: mac
    addr = <<@ethertype::16-big, ifindex::32-native, 0::16, 0::8, 6::8, mac_padded::binary-size(8)>>
    %{family: @af_packet, addr: addr}
  end

  defp iov_data(%{iov: [data | _]}), do: data
  defp iov_data(_), do: <<>>
end
