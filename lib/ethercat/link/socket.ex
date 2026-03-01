defmodule EtherCAT.Link.Socket do
  @moduledoc """
  Raw AF_PACKET socket wrapper for EtherCAT.

  Uses VintageNet for MAC address lookup and `:net` for interface index.
  All low-level socket operations (`open`, `send`, `recv`, `close`)
  operate on the `%Socket{}` struct.
  """

  @af_packet 17
  @ethertype 0x88A4
  @broadcast_mac <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>

  defstruct [:raw, :ifindex, :interface, :src_mac]

  @type t :: %__MODULE__{
          raw: :socket.socket(),
          ifindex: non_neg_integer(),
          interface: String.t(),
          src_mac: <<_::48>>
        }

  @doc "Open a raw AF_PACKET socket bound to the given interface."
  @spec open(String.t()) :: {:ok, t()} | {:error, term()}
  def open(interface) do
    with {:ok, idx} <- ifindex(interface),
         {:ok, src_mac} <- mac_address(interface),
         {:ok, raw} <- :socket.open(@af_packet, :raw, {:raw, @ethertype}),
         :ok <- :socket.bind(raw, sockaddr_ll(idx)) do
      enable_rx_timestamping(raw)

      {:ok,
       %__MODULE__{
         raw: raw,
         ifindex: idx,
         interface: interface,
         src_mac: src_mac
       }}
    end
  end

  @doc "Send a pre-built frame to the broadcast address."
  @spec send(t(), binary()) :: {:ok, integer()} | {:error, term()}
  def send(%__MODULE__{raw: raw, ifindex: idx}, frame) do
    tx_at = System.monotonic_time()
    dest = sockaddr_ll(idx, @broadcast_mac)

    case :socket.sendto(raw, frame, dest) do
      :ok -> {:ok, tx_at}
      {:error, _} = err -> err
    end
  end

  @doc "Non-blocking receive via recvmsg (captures ancillary timestamps)."
  @spec recv(t()) :: {:ok, binary(), integer()} | {:select, term()} | {:error, term()}
  def recv(%__MODULE__{raw: raw}) do
    case :socket.recvmsg(raw, 0, 0, :nowait) do
      {:ok, msg} ->
        {:ok, msg_data(msg), extract_timestamp(msg)}

      {:select, _} = sel ->
        sel

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Arm the socket for the next `$socket` select message.

  If a stale frame is already in the buffer (e.g. a late response from a
  previous timed-out transaction), it is drained recursively until the buffer
  is empty and a select is registered. This prevents stale frames from
  shadowing the next response.

  Must use `recvmsg` (not `recv`) to match `recv/1` — the select
  notification is tied to the specific recv variant that registered it.
  """
  @spec recv_async(t()) :: :ok
  def recv_async(%__MODULE__{raw: raw} = sock) do
    case :socket.recvmsg(raw, 0, 0, :nowait) do
      {:select, _} -> :ok
      {:ok, _} -> recv_async(sock)
      {:error, _} -> :ok
    end
  end

  @doc "Drain all frames currently in the socket buffer; cancel any lingering select."
  @spec drain(t()) :: :ok
  def drain(%__MODULE__{raw: raw} = sock) do
    case :socket.recvmsg(raw, 0, 0, :nowait) do
      {:ok, _} -> drain(sock)
      {:select, si} -> :socket.cancel(raw, si)
      _ -> :ok
    end
  end

  @doc """
  Warm up the NIC's transmit path by sending one dummy EtherCAT frame and
  draining the response.

  On some NICs (e.g. bcmgenet on Raspberry Pi 4) the very first `sendto` call
  after `open/1` takes ~105 ms due to DMA descriptor initialization. Calling
  `warmup/1` right after `open/1` pays that cost eagerly so that real
  transactions see sub-millisecond latency from the start.
  """
  @spec warmup(t()) :: :ok | {:error, term()}
  def warmup(%__MODULE__{} = sock) do
    # Minimum-size Ethernet frame with EtherCAT ethertype and zeroed payload.
    # Slaves will not recognize this as a valid EtherCAT datagram, so no WKC
    # update occurs — it's a NIC TX-path health check and cold-start probe.
    src = sock.src_mac

    frame =
      <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, src::binary, 0x88, 0xA4>> <>
        :binary.copy(<<0>>, 46)

    case __MODULE__.send(sock, frame) do
      {:ok, _tx_at} ->
        # Sleep 150 ms to absorb bcmgenet cold-start latency.
        # Do NOT drain here — calling :socket.cancel on an empty buffer corrupts
        # the socket's internal select state on kernel 6.12 / bcmgenet, causing
        # subsequent recvmsg(:nowait) calls to return {:error, …} instead of
        # {:select, si}.  The warmup response simply sits in the buffer until
        # recv_async drains it as part of the first real transaction.
        :timer.sleep(150)
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc "Close the underlying socket. Returns the struct with `raw` set to `nil`."
  @spec close(t()) :: t()
  def close(%__MODULE__{raw: nil} = sock), do: sock

  def close(%__MODULE__{raw: raw} = sock) do
    :socket.close(raw)
    %{sock | raw: nil}
  end

  @doc "Returns `true` when the socket handle is open."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{raw: nil}), do: false
  def open?(%__MODULE__{}), do: true

  # -- timestamp support ------------------------------------------------------

  # SOL_SOCKET=1, SO_TIMESTAMPING=37
  # Flags: SOF_TIMESTAMPING_RX_SOFTWARE(0x08) | SOF_TIMESTAMPING_SOFTWARE(0x10) = 0x18
  defp enable_rx_timestamping(raw) do
    :socket.setopt(raw, {1, 37}, <<0x18::native-32>>)
  catch
    _, _ -> :ok
  end

  # SOL_SOCKET=1, SCM_TIMESTAMPING=37
  defp extract_timestamp(%{ctrl: ctrl}) when is_list(ctrl) do
    case Enum.find(ctrl, &match?(%{level: 1, type: 37}, &1)) do
      %{data: <<sec::native-64, nsec::native-64, _::binary>>} ->
        System.convert_time_unit(sec * 1_000_000_000 + nsec, :nanosecond, :native)

      _ ->
        System.monotonic_time()
    end
  end

  defp extract_timestamp(_), do: System.monotonic_time()

  defp msg_data(%{iov: [data | _]}), do: data
  defp msg_data(%{iov: _}), do: <<>>

  # -- interface helpers ------------------------------------------------------

  defp ifindex(interface) do
    case :net.if_name2index(String.to_charlist(interface)) do
      {:ok, _idx} = ok -> ok
      {:error, _} = err -> err
    end
  end

  defp mac_address(interface) do
    case VintageNet.get(["interface", interface, "mac_address"]) do
      mac_str when is_binary(mac_str) ->
        mac =
          mac_str
          |> String.split(":")
          |> Enum.map(&String.to_integer(&1, 16))
          |> :binary.list_to_bin()

        {:ok, mac}

      nil ->
        {:error, {:no_mac_address, interface}}
    end
  end

  # -- sockaddr_ll ------------------------------------------------------------

  # struct sockaddr_ll fields after family: protocol(16), ifindex(32),
  # hatype(16), pkttype(8), halen(8), addr(8).
  defp sockaddr_ll(ifindex, mac \\ <<0::48>>) do
    mac_padded =
      if byte_size(mac) < 8, do: <<mac::binary, 0::size((8 - byte_size(mac)) * 8)>>, else: mac

    addr =
      <<@ethertype::16-big, ifindex::32-native, 0::16, 0::8, 6::8, mac_padded::binary-size(8)>>

    %{family: @af_packet, addr: addr}
  end
end
