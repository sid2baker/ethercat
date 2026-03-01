# EtherCAT socket diagnostic — run directly on the target device in IEx.
#
# Four sequential tests to pinpoint where frame exchange breaks down:
#
#   [1] System + interface info
#   [2] Passive sniff (ETH_P_ALL, 3 s)  — proves AF_PACKET receive path works
#   [3] Two-socket echo test            — arms an independent recv socket BEFORE
#                                         sending, removing any send/recv race
#   [4] BRD send/recv (5 frames)        — standard EtherCAT exchange
#
# Usage in IEx:
#   import_file("examples/diag.exs")
#   EtherDiag.run("eth0")
#   EtherDiag.run("eth0", timeout_ms: 2000)

defmodule EtherDiag do
  @af_packet 17
  @ethertype_ecat 0x88A4
  @broadcast_mac <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>

  # ETH_P_ALL in network byte order (htons(0x0003) = 0x0300).
  # AF_PACKET socket() expects protocol in NBO; we pass it directly.
  @eth_p_all 0x0300

  # ---------------------------------------------------------------------------
  # Entry point
  # ---------------------------------------------------------------------------

  def run(interface, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 1_000)
    IO.puts("\n#{bar()}\n  EtherCAT Diagnostic — #{interface}\n#{bar()}\n")

    {idx, mac} = step_info(interface)
    step_sniff(idx, 3_000)
    step_echo(interface, idx, mac, timeout_ms)
    step_brd(interface, idx, mac, timeout_ms, 5)
  end

  # ---------------------------------------------------------------------------
  # [1] System + interface info
  # ---------------------------------------------------------------------------

  defp step_info(interface) do
    kernel =
      case File.read("/proc/version") do
        {:ok, v} -> v |> String.split() |> Enum.at(2, "unknown")
        _        -> "unknown"
      end

    IO.puts("""
    [1] System
      Kernel  : #{kernel}
      OTP     : #{System.otp_release()}
      Elixir  : #{System.version()}
    """)

    lower_up = VintageNet.get(["interface", interface, "lower_up"])
    mac_str  = VintageNet.get(["interface", interface, "mac_address"])
    {:ok, idx} = :net.if_name2index(String.to_charlist(interface))
    mac = decode_mac(mac_str)

    IO.puts("""
    [2] Interface #{interface}
      lower_up : #{inspect(lower_up)}
      mac      : #{inspect(mac_str)}
      ifindex  : #{idx}
    """)

    if lower_up != true, do: IO.puts("  *** carrier DOWN — no frames can be sent or received ***\n")

    {idx, mac}
  end

  # ---------------------------------------------------------------------------
  # [2] Passive sniff — ETH_P_ALL, counts any arriving frame
  #
  # Zero  → interface is idle (normal for a dedicated EtherCAT port with no
  #          active master) OR the kernel/driver blocks AF_PACKET receive.
  # N > 0 → socket receive path is functional.
  # ---------------------------------------------------------------------------

  defp step_sniff(idx, ms) do
    IO.puts("[3] Passive sniff — ETH_P_ALL, #{ms} ms")

    result =
      case :socket.open(@af_packet, :raw, {:raw, @eth_p_all}) do
        {:ok, sock} ->
          case :socket.bind(sock, sockaddr_ll(idx, @eth_p_all)) do
            :ok ->
              n = count_recv(sock, ms)
              :socket.close(sock)
              {:ok, n}

            {:error, r} ->
              :socket.close(sock)
              {:error, {:bind, r}}
          end

        {:error, r} ->
          {:error, {:open, r}}
      end

    case result do
      {:ok, 0} ->
        IO.puts("  → 0 frames — idle interface (normal) or receive path broken\n")

      {:ok, n} ->
        IO.puts("  → #{n} frame(s) received ✓  AF_PACKET receive path works\n")

      {:error, reason} ->
        IO.puts("  → SKIP: #{inspect(reason)}\n")
    end
  end

  # ---------------------------------------------------------------------------
  # [3] Two-socket echo test
  #
  # Arms rx socket BEFORE sending from tx socket. Both listen on the same
  # ethertype; when the EtherCAT slaves echo the frame back, both should see it.
  #
  # RTT < 10 µs → likely kernel self-loopback (outgoing frame echoed by driver)
  # RTT ≥ 50 µs → genuine hardware echo from slave(s)
  # timeout     → no echo received (no slaves / not powered / ring not closed)
  # ---------------------------------------------------------------------------

  defp step_echo(interface, idx, mac, timeout_ms) do
    IO.puts("[4] Two-socket echo test — #{timeout_ms} ms")

    with {:ok, tx} <- :socket.open(@af_packet, :raw, {:raw, @ethertype_ecat}),
         :ok       <- :socket.bind(tx, sockaddr_ll(idx)),
         {:ok, rx} <- :socket.open(@af_packet, :raw, {:raw, @ethertype_ecat}),
         :ok       <- :socket.bind(rx, sockaddr_ll(idx)) do
      drain(rx)
      frame = build_brd_frame(mac, 0xEE)
      dest  = sockaddr_ll(idx, @broadcast_mac)

      result =
        case :socket.recvmsg(rx, 0, 0, :nowait) do
          {:select, si} ->
            {:select_info, _, ref} = si
            t0 = System.monotonic_time(:microsecond)
            :ok = :socket.sendto(tx, frame, dest)

            receive do
              {:"$socket", ^rx, :select, ^ref} ->
                case :socket.recvmsg(rx, 0, 0, :nowait) do
                  {:ok, msg} ->
                    rtt = System.monotonic_time(:microsecond) - t0
                    {:ok, iov_data(msg), rtt}

                  _ ->
                    :timeout
                end
            after
              timeout_ms ->
                :socket.cancel(rx, si)
                :timeout
            end

          {:ok, _stale} ->
            drain(rx)
            :stale

          _ ->
            :timeout
        end

      :socket.close(tx)
      :socket.close(rx)

      case result do
        {:ok, data, rtt} ->
          wkc  = parse_wkc(data)
          note = if rtt < 10, do: "  ← very fast, may be kernel self-loopback", else: ""
          IO.puts("  → echo in #{rtt} µs, wkc=#{inspect(wkc)}#{note}\n")

        :timeout ->
          IO.puts("""
            → TIMEOUT — echo did not return
              Most likely: no EtherCAT slave on #{interface}
                       or: slave not powered
                       or: ring not closed (last slave's port-B must loop back)
          """)

        :stale ->
          IO.puts("  → stale frame was in rx buffer; re-run\n")
      end
    else
      {:error, r} ->
        IO.puts("  → SKIP: socket failed: #{inspect(r)}\n")
    end
  end

  # ---------------------------------------------------------------------------
  # [4] BRD send/recv — 5 frames, configurable timeout
  # ---------------------------------------------------------------------------

  defp step_brd(interface, idx, mac, timeout_ms, n) do
    IO.puts("[5] BRD send/recv — #{n} frames, #{timeout_ms} ms timeout")

    sample = build_brd_frame(mac, 1)
    IO.puts("  Frame (#{byte_size(sample)} B): #{Base.encode16(sample, case: :lower)}\n")

    case :socket.open(@af_packet, :raw, {:raw, @ethertype_ecat}) do
      {:ok, sock} ->
        :ok = :socket.bind(sock, sockaddr_ll(idx))
        drain(sock)

        results =
          Enum.map(1..n, fn i ->
            frame = build_brd_frame(mac, i)
            dest  = sockaddr_ll(idx, @broadcast_mac)
            :ok   = :socket.sendto(sock, frame, dest)
            t0    = System.monotonic_time(:microsecond)

            case poll_recv(sock, timeout_ms) do
              {:ok, data, t1} ->
                IO.puts("  frame #{pad(i)}: ok  #{t1 - t0} µs  wkc=#{inspect(parse_wkc(data))}")
                :ok

              :timeout ->
                IO.puts("  frame #{pad(i)}: TIMEOUT (#{timeout_ms} ms)")
                :timeout
            end
          end)

        :socket.close(sock)
        ok_n = Enum.count(results, &(&1 == :ok))
        IO.puts("\n  #{ok_n}/#{n} frames returned from #{interface}\n")

      {:error, r} ->
        IO.puts("  socket open failed: #{inspect(r)}\n")
    end
  end

  # ---------------------------------------------------------------------------
  # Frame encoding — identical to Frame.encode + Datagram.encode
  #
  # Both EtherCAT header and datagram length field are packed MSB-first
  # (big-endian) then written to wire as little-endian 16-bit values.
  # ---------------------------------------------------------------------------

  defp build_brd_frame(src_mac, seq) do
    <<byte_idx>> = <<seq::8>>

    # Datagram length field: M[15]=0 | C[14]=0 | R[13:11]=0 | Len[10:0]=1
    <<dg_len::big-16>> = <<0::1, 0::1, 0::3, 1::11>>

    datagram = <<
      7::8,                # CMD = BRD
      byte_idx::8,         # IDX
      0::32,               # address (ADP=0, ADO=0)
      dg_len::little-16,   # length + flags
      0::16,               # IRQ
      0::8,                # data (1 byte)
      0::16                # WKC
    >>

    # EtherCAT header: Type[15:12]=1 | R[11]=0 | Len[10:0]
    <<ec_hdr::big-16>> = <<1::4, 0::1, byte_size(datagram)::11>>

    raw = <<
      @broadcast_mac::binary,
      src_mac::binary-size(6),
      @ethertype_ecat::16-big,
      ec_hdr::little-16,
      datagram::binary
    >>

    # Pad to Ethernet minimum (60 bytes; FCS added by NIC)
    pad_bytes = max(0, 60 - byte_size(raw))
    <<raw::binary, 0::size(pad_bytes * 8)>>
  end

  # WKC sits at Ethernet(14) + EC hdr(2) + datagram hdr(10) + data(1) = byte 27
  defp parse_wkc(<<_eth::112, _ec::16, _dg_hdr::80, _data::8, wkc::little-16, _::binary>>),
    do: wkc

  defp parse_wkc(_), do: nil

  # ---------------------------------------------------------------------------
  # Socket helpers
  # ---------------------------------------------------------------------------

  defp poll_recv(sock, timeout_ms) do
    case :socket.recvmsg(sock, 0, 0, :nowait) do
      {:ok, msg} ->
        {:ok, iov_data(msg), System.monotonic_time(:microsecond)}

      {:select, si} ->
        {:select_info, _, ref} = si

        receive do
          {:"$socket", ^sock, :select, ^ref} ->
            case :socket.recvmsg(sock, 0, 0, :nowait) do
              {:ok, msg} -> {:ok, iov_data(msg), System.monotonic_time(:microsecond)}
              _          -> :timeout
            end
        after
          timeout_ms ->
            :socket.cancel(sock, si)
            :timeout
        end

      _ ->
        :timeout
    end
  end

  defp count_recv(sock, ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    count_loop(sock, deadline, 0)
  end

  defp count_loop(sock, deadline, n) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      n
    else
      case :socket.recvmsg(sock, 0, 0, :nowait) do
        {:ok, _} ->
          count_loop(sock, deadline, n + 1)

        {:select, si} ->
          {:select_info, _, ref} = si

          receive do
            {:"$socket", ^sock, :select, ^ref} ->
              count_loop(sock, deadline, n)
          after
            left ->
              :socket.cancel(sock, si)
              n
          end

        _ ->
          n
      end
    end
  end

  defp drain(sock) do
    case :socket.recvmsg(sock, 0, 0, :nowait) do
      {:ok, _}      -> drain(sock)
      {:select, si} -> :socket.cancel(sock, si)
      _             -> :ok
    end
  end

  defp iov_data(%{iov: [d | _]}), do: d
  defp iov_data(_), do: <<>>

  # bind (no destination MAC)
  defp sockaddr_ll(ifindex) do
    addr = <<@ethertype_ecat::16-big, ifindex::32-native, 0::16, 0::8, 6::8, 0::64>>
    %{family: @af_packet, addr: addr}
  end

  # sendto destination MAC
  defp sockaddr_ll(ifindex, mac) when is_binary(mac) do
    pad = max(0, 8 - byte_size(mac))
    addr = <<@ethertype_ecat::16-big, ifindex::32-native, 0::16, 0::8, 6::8, mac::binary, 0::size(pad * 8)>>
    %{family: @af_packet, addr: addr}
  end

  # integer protocol (ETH_P_ALL bind)
  defp sockaddr_ll(ifindex, proto) when is_integer(proto) do
    addr = <<proto::16-big, ifindex::32-native, 0::16, 0::8, 0::8, 0::64>>
    %{family: @af_packet, addr: addr}
  end

  defp decode_mac(nil), do: <<0, 0, 0, 0, 0, 0>>
  defp decode_mac(s), do: s |> String.split(":") |> Enum.map(&String.to_integer(&1, 16)) |> :binary.list_to_bin()

  defp pad(i), do: String.pad_leading(to_string(i), 2)
  defp bar, do: String.duplicate("─", 60)
end
