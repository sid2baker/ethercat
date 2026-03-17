defmodule EtherCAT.Bus.Transport.RawSocket do
  @moduledoc """
  Raw AF_PACKET socket transport for EtherCAT.

  Sends and receives full Ethernet frames with EtherType 0x88A4.
  Implements the `EtherCAT.Bus.Transport` behaviour.

  Uses sysfs for MAC address lookup and `:net` for interface index.
  The EtherCAT payload (from `Bus.Frame.encode/1`) is wrapped in a standard
  Ethernet frame internally — callers only deal with EtherCAT payloads.
  """

  @behaviour EtherCAT.Bus.Transport

  # Suppress conflict with Kernel.send/2 — this module defines its own send/2
  import Kernel, except: [send: 2]

  alias EtherCAT.Bus.InterfaceInfo
  alias EtherCAT.Telemetry

  @af_packet 17
  @ethertype 0x88A4
  @broadcast_mac <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
  @zero_mac <<0, 0, 0, 0, 0, 0>>
  @min_frame_size 60
  @select_receive_retries 3

  defstruct [:raw, :ifindex, :interface, :src_mac, drop_outgoing_echo?: false]

  @type t :: %__MODULE__{
          raw: :socket.socket() | nil,
          ifindex: non_neg_integer(),
          interface: String.t(),
          src_mac: <<_::48>>,
          drop_outgoing_echo?: boolean()
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
         src_mac: src_mac,
         drop_outgoing_echo?: Keyword.get(opts, :drop_outgoing_echo?, false)
       }}
    end
  end

  @impl true
  @doc "Send an EtherCAT payload wrapped in an Ethernet frame."
  @spec send(t(), binary()) :: {:ok, integer()} | {:error, term()}
  def send(%__MODULE__{raw: nil}, _ecat_payload), do: {:error, :closed}

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
  def set_active_once(%__MODULE__{raw: nil}), do: :ok
  def set_active_once(%__MODULE__{} = sock), do: arm_receive_once(sock)

  @impl true
  @doc "Re-arm without draining — self-sends a select notification."
  @spec rearm(t()) :: :ok
  def rearm(%__MODULE__{raw: nil}), do: :ok

  def rearm(%__MODULE__{raw: raw}) do
    Kernel.send(self(), {:"$socket", raw, :select, :buffered})
    :ok
  end

  @impl true
  @doc """
  Match a `{:"$socket", raw, :select, _}` message from this socket.

  When matched, calls `recvmsg` internally to read the frame, strips the
  Ethernet headers, and returns the EtherCAT payload with an rx timestamp
  and the frame's source MAC address (6 bytes).
  Returns `:ignore` for all other messages or non-EtherCAT frames.
  """
  @spec match(t(), term()) :: {:ok, binary(), integer(), binary()} | :ignore
  def match(%__MODULE__{raw: raw} = sock, {:"$socket", raw, :select, _}),
    do: recv_ethercat_payload(sock, @select_receive_retries)

  def match(%__MODULE__{raw: raw}, {:ethercat_raw_payload, raw, payload, rx_at, frame_src_mac}),
    do: {:ok, payload, rx_at, frame_src_mac}

  def match(%__MODULE__{}, _msg), do: :ignore

  @impl true
  @doc "Returns this NIC's source MAC address (6 bytes)."
  @spec src_mac(t()) :: <<_::48>>
  def src_mac(%__MODULE__{src_mac: mac}), do: mac

  @impl true
  @doc "Drain all frames in the socket buffer; cancel any lingering select."
  @spec drain(t()) :: :ok
  def drain(%__MODULE__{raw: nil}), do: :ok

  def drain(%__MODULE__{raw: raw} = sock) do
    case :socket.recvmsg(raw, 0, 0, :nowait) do
      {:ok, _} -> drain(sock)
      {:select, si} -> :socket.cancel(raw, si)
      _ -> :ok
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
  @doc "Returns the network interface name for telemetry and link monitoring."
  @spec name(t()) :: String.t()
  def name(%__MODULE__{interface: iface}), do: iface

  @impl true
  @doc "Returns the interface name used by the bus link monitor."
  @spec interface(t()) :: String.t()
  def interface(%__MODULE__{interface: iface}), do: iface

  # -- private ----------------------------------------------------------------

  defp arm_receive_once(%__MODULE__{raw: raw} = sock) do
    case :socket.recvmsg(raw, 0, 0, :nowait) do
      {:select, _} ->
        :ok

      {:ok, msg} ->
        case extract_buffered_payload(sock, msg) do
          {:ok, payload, rx_at, frame_src_mac} ->
            Kernel.send(self(), {:ethercat_raw_payload, raw, payload, rx_at, frame_src_mac})
            :ok

          :ignore ->
            arm_receive_once(sock)
        end

      {:error, _} ->
        :ok
    end
  end

  defp recv_ethercat_payload(%__MODULE__{raw: raw} = sock, retries_left) do
    case :socket.recvmsg(raw, 0, 0, :nowait) do
      {:ok, msg} ->
        case extract_buffered_payload(sock, msg) do
          {:ok, ecat_payload, rx_at, frame_src_mac} ->
            {:ok, ecat_payload, rx_at, frame_src_mac}

          :ignore ->
            recv_ethercat_payload(sock, retries_left)
        end

      {:select, _} when retries_left > 0 ->
        recv_ethercat_payload(sock, retries_left - 1)

      {:select, _} ->
        :ignore

      {:error, _reason} when retries_left > 0 ->
        recv_ethercat_payload(sock, retries_left - 1)

      {:error, _reason} ->
        :ignore
    end
  end

  defp extract_buffered_payload(%__MODULE__{} = sock, msg) do
    if outgoing_echo?(sock, msg) do
      :ignore
    else
      rx_at = extract_timestamp(msg)
      raw_frame = msg_data(msg)

      case strip_ethernet_headers(raw_frame) do
        {:ok, ecat_payload, frame_src_mac} ->
          {:ok, ecat_payload, rx_at, frame_src_mac}

        {:error, reason} ->
          Telemetry.frame_dropped(sock.interface, byte_size(raw_frame), reason)
          :ignore
      end
    end
  end

  defp outgoing_echo?(%__MODULE__{drop_outgoing_echo?: true}, %{
         addr: %{pkttype: :outgoing}
       }),
       do: true

  defp outgoing_echo?(%__MODULE__{}, _msg), do: false

  defp strip_ethernet_headers(<<
         _dst::binary-size(6),
         src::binary-size(6),
         0x88A4::big-unsigned-16,
         rest::binary
       >>) do
    if valid_source_mac?(src), do: {:ok, rest, src}, else: {:error, :invalid_source_mac}
  end

  # VLAN-tagged frame (802.1Q)
  defp strip_ethernet_headers(<<
         _dst::binary-size(6),
         src::binary-size(6),
         0x8100::big-unsigned-16,
         _vlan::binary-size(2),
         0x88A4::big-unsigned-16,
         rest::binary
       >>) do
    if valid_source_mac?(src), do: {:ok, rest, src}, else: {:error, :invalid_source_mac}
  end

  defp strip_ethernet_headers(_), do: {:error, :not_ethercat}

  defp valid_source_mac?(mac), do: mac not in [@broadcast_mac, @zero_mac]

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
    InterfaceInfo.mac_address(interface)
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
