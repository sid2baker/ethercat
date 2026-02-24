defmodule EtherCAT.Link.Socket do
  @moduledoc """
  Raw AF_PACKET socket wrapper for EtherCAT.

  Encapsulates the Erlang `:socket` handle, interface index, interface name,
  and source MAC into a single struct. All low-level socket operations
  (`open`, `send`, `recv`, `close`) operate on this struct.
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
    with {:ok, idx} <- ifindex(String.to_charlist(interface)),
         {:ok, src_mac} <- read_mac(interface),
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
    else
      {:error, _} = err -> err
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
        data = msg_data(msg)
        rx_at = extract_timestamp(msg)
        {:ok, data, rx_at}

      {:select, _} = sel ->
        sel

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Arm the socket for the next `$socket` select message.

  Must use `recvmsg` (not `recv`) to match `recv/1` — the select
  notification is tied to the specific recv variant that registered it.
  """
  @spec recv_async(t()) :: :ok
  def recv_async(%__MODULE__{raw: raw}) do
    case :socket.recvmsg(raw, 0, 0, :nowait) do
      {:select, _} -> :ok
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  @doc "Close the underlying socket."
  @spec close(t()) :: :ok
  def close(%__MODULE__{raw: raw}), do: :socket.close(raw)

  # -- timestamp support ------------------------------------------------------

  # Best-effort enable SO_TIMESTAMPING for RX software timestamps.
  # SOL_SOCKET=1, SO_TIMESTAMPING=37
  # Flags: SOF_TIMESTAMPING_RX_SOFTWARE(0x08) | SOF_TIMESTAMPING_SOFTWARE(0x10) = 0x18
  defp enable_rx_timestamping(raw) do
    :socket.setopt(raw, {1, 37}, <<0x18::native-32>>)
  catch
    _, _ -> :ok
  end

  # Extract RX timestamp from recvmsg ancillary data.
  # SOL_SOCKET=1, SCM_TIMESTAMPING=37. Kernel delivers a struct with
  # three timespecs; the software timestamp is the first one.
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

  defp ifindex(name) do
    case :net.getifaddrs(%{family: :packet}) do
      {:ok, addrs} ->
        case Enum.find(addrs, &(&1.name == name)) do
          %{addr: addr} -> {:ok, addr.ifindex}
          nil -> {:error, {:interface_not_found, name}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp read_mac(interface) do
    path = "/sys/class/net/#{interface}/address"

    with {:ok, contents} <- File.read(path) do
      mac =
        contents
        |> String.trim()
        |> String.split(":")
        |> Enum.map(&String.to_integer(&1, 16))
        |> :binary.list_to_bin()

      {:ok, mac}
    end
  end

  # Build a sockaddr_ll binary for AF_PACKET bind/sendto.
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
