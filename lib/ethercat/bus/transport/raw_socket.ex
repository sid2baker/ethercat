defmodule EtherCAT.Bus.Transport.RawSocket do
  @moduledoc """
  Raw AF_PACKET socket transport for EtherCAT.

  Sends and receives full Ethernet frames with EtherType 0x88A4.
  Implements the `EtherCAT.Bus.Transport` behaviour.

  Uses VintageNet for MAC address lookup and `:net` for interface index.
  The EtherCAT payload (from `Bus.Frame.encode/1`) is wrapped in a standard
  Ethernet frame internally — callers only deal with EtherCAT payloads.
  """

  @behaviour EtherCAT.Bus.Transport

  # Suppress conflict with Kernel.send/2 — this module defines its own send/2
  import Kernel, except: [send: 2]

  @af_packet 17
  @ethertype 0x88A4
  @broadcast_mac <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
  @min_frame_size 60

  defstruct [:raw, :ifindex, :interface, :src_mac]

  @type t :: %__MODULE__{
          raw: :socket.socket() | nil,
          ifindex: non_neg_integer(),
          interface: String.t(),
          src_mac: <<_::48>>
        }

  @impl true
  @doc "Open a raw AF_PACKET socket bound to the given interface."
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts) do
    interface = Keyword.fetch!(opts, :interface)

    with {:ok, idx} <- ifindex(interface),
         {:ok, src_mac} <- mac_address(interface),
         {:ok, raw} <- :socket.open(@af_packet, :raw, {:raw, @ethertype}),
         :ok <- :socket.bind(raw, sockaddr_ll(idx)) do
      enable_rx_timestamping(raw)
      enable_busy_poll(raw)

      {:ok,
       %__MODULE__{
         raw: raw,
         ifindex: idx,
         interface: interface,
         src_mac: src_mac
       }}
    end
  end

  @impl true
  @doc "Send an EtherCAT payload wrapped in an Ethernet frame."
  @spec send(t(), binary()) :: {:ok, integer()} | {:error, term()}
  def send(%__MODULE__{raw: raw, ifindex: idx, src_mac: src}, ecat_payload) do
    tx_at = System.monotonic_time()
    dest = sockaddr_ll(idx, @broadcast_mac)

    frame_body = <<
      @broadcast_mac::binary,
      src::binary-size(6),
      @ethertype::big-unsigned-16,
      ecat_payload::binary
    >>

    pad_needed = max(0, @min_frame_size - byte_size(frame_body))
    frame = <<frame_body::binary, 0::size(pad_needed)-unit(8)>>

    case :socket.sendto(raw, frame, dest) do
      :ok -> {:ok, tx_at}
      {:error, _} = err -> err
    end
  end

  @impl true
  @doc "Arm for one async receive via `:socket` select mechanism."
  @spec set_active_once(t()) :: :ok
  def set_active_once(%__MODULE__{} = sock), do: recv_async(sock)

  @impl true
  @doc """
  Match a `{:"$socket", raw, :select, _}` message from this socket.

  When matched, calls `recvmsg` internally to read the frame, strips the
  Ethernet headers, and returns the EtherCAT payload with an rx timestamp.
  Returns `:ignore` for all other messages or non-EtherCAT frames.
  """
  @spec match(t(), term()) :: {:ok, binary(), integer()} | :ignore
  def match(%__MODULE__{raw: raw} = sock, {:"$socket", raw, :select, _}) do
    case :socket.recvmsg(raw, 0, 0, :nowait) do
      {:ok, msg} ->
        rx_at = extract_timestamp(msg)
        raw_frame = msg_data(msg)

        case strip_ethernet_headers(raw_frame) do
          {:ok, ecat_payload} ->
            {:ok, ecat_payload, rx_at}

          # Not an EtherCAT frame — arm again and ignore
          {:error, _} ->
            recv_async(sock)
            :ignore
        end

      {:select, _} ->
        :ignore

      {:error, _} ->
        :ignore
    end
  end

  def match(%__MODULE__{}, _msg), do: :ignore

  @impl true
  @doc "Drain all frames in the socket buffer; cancel any lingering select."
  @spec drain(t()) :: :ok
  def drain(%__MODULE__{raw: raw} = sock) do
    case :socket.recvmsg(raw, 0, 0, :nowait) do
      {:ok, _} -> drain(sock)
      {:select, si} -> :socket.cancel(raw, si)
      _ -> :ok
    end
  end

  @impl true
  @doc """
  Warm up the NIC's transmit path by sending one dummy EtherCAT frame.

  On some NICs (e.g. bcmgenet on Raspberry Pi 4) the very first `sendto`
  after `open/1` takes ~105 ms due to DMA descriptor initialization. Calling
  `warmup/1` right after `open/1` pays that cost eagerly.
  """
  @spec warmup(t()) :: :ok | {:error, term()}
  def warmup(%__MODULE__{} = sock) do
    # Minimal EtherCAT payload: header (2 bytes) + one NOP datagram (12 bytes).
    # The NOP (cmd=0) is not processed by slaves — it's a NIC TX-path probe.
    alias EtherCAT.Bus.{Datagram, Frame}
    {:ok, payload} = Frame.encode([%Datagram{}])

    case send(sock, payload) do
      {:ok, _tx_at} ->
        # Sleep 150 ms to absorb bcmgenet cold-start latency.
        # Do NOT drain here — see original Socket.warmup/1 for rationale.
        :timer.sleep(150)
        :ok

      {:error, _} = err ->
        err
    end
  end

  @impl true
  @doc "Close the underlying socket. Returns the struct with `raw` set to `nil`."
  @spec close(t()) :: t()
  def close(%__MODULE__{raw: nil} = sock), do: sock

  def close(%__MODULE__{raw: raw} = sock) do
    :socket.close(raw)
    %{sock | raw: nil}
  end

  @impl true
  @doc "Returns `true` when the socket handle is open."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{raw: nil}), do: false
  def open?(%__MODULE__{}), do: true

  @impl true
  @doc "Returns the network interface name for telemetry and VintageNet subscriptions."
  @spec name(t()) :: String.t()
  def name(%__MODULE__{interface: iface}), do: iface

  @impl true
  @doc "Returns the interface name (used for VintageNet carrier subscriptions)."
  @spec interface(t()) :: String.t()
  def interface(%__MODULE__{interface: iface}), do: iface

  # -- private ----------------------------------------------------------------

  defp recv_async(%__MODULE__{raw: raw} = sock) do
    case :socket.recvmsg(raw, 0, 0, :nowait) do
      {:select, _} -> :ok
      {:ok, _} -> recv_async(sock)
      {:error, _} -> :ok
    end
  end

  defp strip_ethernet_headers(<<
         _dst::binary-size(6),
         _src::binary-size(6),
         0x88A4::big-unsigned-16,
         rest::binary
       >>),
       do: {:ok, rest}

  # VLAN-tagged frame (802.1Q)
  defp strip_ethernet_headers(<<
         _dst::binary-size(6),
         _src::binary-size(6),
         0x8100::big-unsigned-16,
         _vlan::binary-size(2),
         0x88A4::big-unsigned-16,
         rest::binary
       >>),
       do: {:ok, rest}

  defp strip_ethernet_headers(_), do: {:error, :not_ethercat}

  # -- timestamp support ------------------------------------------------------

  # SOL_SOCKET=1, SO_TIMESTAMPING=37
  # Flags: SOF_TIMESTAMPING_RX_SOFTWARE(0x08) | SOF_TIMESTAMPING_SOFTWARE(0x10) = 0x18
  defp enable_rx_timestamping(raw) do
    :socket.setopt(raw, {1, 37}, <<0x18::native-32>>)
  catch
    _, _ -> :ok
  end

  # SOL_SOCKET=1, SO_BUSY_POLL=46 — spin-poll the socket for up to 100 µs before
  # sleeping on interrupt. Eliminates coalescing latency on NICs that support it
  # (e.g. Intel). Silently ignored on NICs without NAPI busy-poll support (e.g.
  # bcmgenet on RPi 4) — harmless either way.
  defp enable_busy_poll(raw) do
    :socket.setopt(raw, {1, 46}, <<100::native-32>>)
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
