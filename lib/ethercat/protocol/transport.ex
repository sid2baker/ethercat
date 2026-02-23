defmodule Ethercat.Protocol.Transport do
  @moduledoc """
  Sequential AF_PACKET transport. One frame is allowed in flight at a time. The
  implementation is intentionally simple so it can be replaced with a more
  advanced batching transport later without impacting callers.
  """

  use GenServer

  alias Ethercat.Protocol.{Datagram, Frame}

  @af_packet 17
  @sock_raw :raw
  @ether_type 0x88A4

  @type datagram :: Datagram.t()

  # -- Public API -----------------------------------------------------------

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec transact(pid() | atom(), [datagram], non_neg_integer()) ::
          {:ok, [datagram]} | {:error, term()}
  def transact(server \\ __MODULE__, datagrams, timeout_us) when is_list(datagrams) do
    GenServer.call(server, {:transact, datagrams, timeout_us}, :infinity)
  end

  # -- Callbacks ------------------------------------------------------------

  @impl true
  def init(opts) do
    interface = Keyword.fetch!(opts, :interface)
    dest_mac = Keyword.get(opts, :dest_mac, <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>)

    {:ok, ifindex} = :net.if_name2index(String.to_charlist(interface))
    {:ok, src_mac} = read_mac(interface)
    {:ok, socket} = open_socket(ifindex)

    dest = sockaddr_ll(ifindex, dest_mac)

    {:ok,
     %{
       socket: socket,
       src_mac: src_mac,
       dest: dest,
       last_index: 0,
       interface: interface
     }}
  end

  @impl true
  def handle_call({:transact, datagrams, timeout_us}, _from, state) do
    {indexed, next_idx} = assign_indices(datagrams, state.last_index)
    frame = Frame.build(indexed, src_mac: state.src_mac)

    with :ok <- :socket.sendto(state.socket, frame, state.dest),
         {:ok, resp_frame} <- recv_frame(state.socket, state.src_mac, timeout_us),
         {:ok, parsed} <- Frame.parse(resp_frame) do
      {:reply, {:ok, parsed}, %{state | last_index: next_idx}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, %{socket: socket}) do
    :socket.close(socket)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Internal helpers ----------------------------------------------------

  defp open_socket(ifindex) do
    case :socket.open(@af_packet, @sock_raw, {:raw, @ether_type}) do
      {:ok, socket} ->
        case :socket.bind(socket, sockaddr_ll(ifindex, <<0::48>>)) do
          :ok -> {:ok, socket}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sockaddr_ll(ifindex, mac) do
    mac = pad_mac(mac)

    addr =
      <<@ether_type::16-big, ifindex::32-native, 0::16, 0::8, 6::8, mac::binary-size(8)>>

    %{family: @af_packet, addr: addr}
  end

  defp pad_mac(mac) when byte_size(mac) == 6, do: <<mac::binary, 0::16>>
  defp pad_mac(mac) when byte_size(mac) == 8, do: mac

  defp pad_mac(mac) when byte_size(mac) < 6 do
    pad = 6 - byte_size(mac)
    <<mac::binary, 0::size(pad * 8), 0::16>>
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

  defp assign_indices(datagrams, start_index) do
    Enum.map_reduce(datagrams, start_index, fn dg, idx ->
      new_idx = rem(idx + 1, 256)
      {%{dg | index: new_idx}, new_idx}
    end)
  end

  defp recv_frame(socket, src_mac, timeout_us) do
    deadline = System.monotonic_time(:microsecond) + timeout_us
    do_recv(socket, src_mac, deadline)
  end

  defp do_recv(socket, src_mac, deadline) do
    current = System.monotonic_time(:microsecond)

    if current >= deadline do
      {:error, :timeout}
    else
      timeout_ms = max(div(deadline - current, 1000), 1)

      case :socket.recv(socket, 2048, [], timeout_ms) do
        {:ok, frame} ->
          case ethercat_frame_src(frame) do
            {:ok, ^src_mac} ->
              # AF_PACKET echoes our sent frame; skip it.
              do_recv(socket, src_mac, deadline)

            {:ok, _other} ->
              {:ok, frame}

            :error ->
              do_recv(socket, src_mac, deadline)
          end

        {:error, :timeout} ->
          do_recv(socket, src_mac, deadline)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ethercat_frame_src(
         <<_dst::binary-size(6), src::binary-size(6), @ether_type::16, _rest::binary>>
       ),
       do: {:ok, src}

  defp ethercat_frame_src(_), do: :error
end
