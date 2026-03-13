defmodule EtherCAT.Simulator.RawSocket do
  @moduledoc """
  Raw AF_PACKET endpoint for `EtherCAT.Simulator`.

  This binds a real EtherType `0x88A4` raw socket on a host interface and
  forwards received EtherCAT frames to the in-memory simulator segment.

  It is the raw-wire sibling of `EtherCAT.Simulator.Udp`: the simulator core
  still executes datagrams, but the outer framing is now a real Ethernet
  header instead of UDP.
  """

  use GenServer

  require Logger

  alias EtherCAT.Bus.Frame
  alias EtherCAT.Simulator

  @af_packet 17
  @ethertype 0x88A4
  @default_name __MODULE__
  @echo_retention_ms 100

  @type state :: %{
          socket: :socket.socket(),
          interface: String.t(),
          ifindex: non_neg_integer(),
          recent_tx_frames: [{binary(), integer()}]
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, @default_name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @default_name))
  end

  @spec info(GenServer.server()) :: {:ok, map()} | {:error, :not_found}
  def info(name \\ @default_name) do
    GenServer.call(name, :info)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, _reason -> {:error, :not_found}
  end

  @impl true
  def init(opts) do
    interface = Keyword.fetch!(opts, :interface)

    with {:ok, ifindex} <- :net.if_name2index(String.to_charlist(interface)),
         {:ok, socket} <- :socket.open(@af_packet, :raw, {:raw, @ethertype}),
         :ok <- :socket.bind(socket, sockaddr_ll(ifindex)) do
      :ok = arm_receive(socket)

      {:ok,
       %{
         socket: socket,
         interface: interface,
         ifindex: ifindex,
         recent_tx_frames: []
       }}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply,
     {:ok,
      %{
        interface: state.interface,
        ifindex: state.ifindex,
        recent_tx_frame_count: length(state.recent_tx_frames)
      }}, state}
  end

  @impl true
  def handle_info({:"$socket", socket, :select, _}, %{socket: socket} = state) do
    {:noreply, receive_ready_frames(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{socket: socket}) do
    :socket.close(socket)
    :ok
  end

  defp receive_ready_frames(%{socket: socket} = state) do
    case :socket.recvmsg(socket, 0, 0, :nowait) do
      {:ok, msg} ->
        state
        |> process_raw_message(msg)
        |> receive_ready_frames()

      {:select, _} ->
        state

      {:error, _reason} ->
        :ok = arm_receive(socket)
        state
    end
  end

  defp process_raw_message(%{socket: socket} = state, msg) do
    state = prune_recent_tx_frames(state)
    raw_frame = msg_data(msg)

    case pop_recent_tx_frame(state, raw_frame) do
      {:echo, updated} ->
        updated

      :miss ->
        with {:ok, response_header, payload, padding, requester_mac} <-
               split_ethercat_frame(raw_frame),
             {:ok, datagrams} <- Frame.decode(payload),
             :request <- classify_payload(datagrams),
             {:ok, response_datagrams} <- Simulator.process_datagrams(datagrams),
             {:ok, response_payload} <- Frame.encode(response_datagrams),
             reply_frame <- <<response_header::binary, response_payload::binary, padding::binary>>,
             :ok <- :socket.sendto(socket, reply_frame, sockaddr_ll(state.ifindex, requester_mac)) do
          remember_tx_frame(state, reply_frame)
        else
          :ignore ->
            state

          {:error, :no_response} ->
            state

          {:error, reason} ->
            Logger.warning(
              "[EtherCAT.Simulator.RawSocket] dropped invalid raw frame: #{inspect(reason)}"
            )

            state
        end
    end
  end

  defp classify_payload(datagrams) do
    if Enum.any?(datagrams, &(&1.wkc != 0 or &1.circular)) do
      :ignore
    else
      :request
    end
  end

  defp split_ethercat_frame(
         <<destination_mac::binary-size(6), source_mac::binary-size(6),
           @ethertype::big-unsigned-16, payload_with_padding::binary>>
       ) do
    with {:ok, payload, padding} <- split_payload_and_padding(payload_with_padding) do
      {:ok, <<source_mac::binary, destination_mac::binary, @ethertype::big-unsigned-16>>, payload,
       padding, source_mac}
    end
  end

  defp split_ethercat_frame(
         <<destination_mac::binary-size(6), source_mac::binary-size(6), 0x8100::big-unsigned-16,
           vlan_tag::binary-size(2), @ethertype::big-unsigned-16, payload_with_padding::binary>>
       ) do
    with {:ok, payload, padding} <- split_payload_and_padding(payload_with_padding) do
      {:ok,
       <<source_mac::binary, destination_mac::binary, 0x8100::big-unsigned-16, vlan_tag::binary,
         @ethertype::big-unsigned-16>>, payload, padding, source_mac}
    end
  end

  defp split_ethercat_frame(_frame), do: {:error, :not_ethercat}

  defp split_payload_and_padding(<<ecat_header::little-unsigned-16, _rest::binary>> = payload) do
    <<type::4, _reserved::1, len::11>> = <<ecat_header::big-unsigned-16>>
    payload_size = 2 + len

    cond do
      type != 1 ->
        {:error, :unsupported_type}

      byte_size(payload) < payload_size ->
        {:error, :truncated_payload}

      true ->
        <<ecat_payload::binary-size(payload_size), padding::binary>> = payload
        {:ok, ecat_payload, padding}
    end
  end

  defp split_payload_and_padding(_payload), do: {:error, :truncated_payload}

  defp remember_tx_frame(%{recent_tx_frames: recent_tx_frames} = state, frame) do
    timestamp_ms = System.monotonic_time(:millisecond)
    %{state | recent_tx_frames: [{frame, timestamp_ms} | Enum.take(recent_tx_frames, 7)]}
  end

  defp prune_recent_tx_frames(%{recent_tx_frames: recent_tx_frames} = state) do
    now_ms = System.monotonic_time(:millisecond)

    %{
      state
      | recent_tx_frames:
          Enum.filter(recent_tx_frames, fn {_frame, sent_at_ms} ->
            now_ms - sent_at_ms <= @echo_retention_ms
          end)
    }
  end

  defp pop_recent_tx_frame(%{recent_tx_frames: recent_tx_frames} = state, frame) do
    case Enum.split_while(recent_tx_frames, fn {recent_frame, _sent_at_ms} ->
           recent_frame != frame
         end) do
      {_prefix, []} ->
        :miss

      {prefix, [_match | suffix]} ->
        {:echo, %{state | recent_tx_frames: prefix ++ suffix}}
    end
  end

  defp arm_receive(socket) do
    case :socket.recvmsg(socket, 0, 0, :nowait) do
      {:select, _} -> :ok
      {:ok, _msg} -> arm_receive(socket)
      {:error, _reason} -> :ok
    end
  end

  defp sockaddr_ll(ifindex, mac \\ <<0::48>>) do
    mac_padded = if byte_size(mac) < 8, do: mac <> <<0::16>>, else: mac

    addr =
      <<@ethertype::16-big, ifindex::32-native, 0::16, 0::8, 6::8, mac_padded::binary-size(8)>>

    %{family: @af_packet, addr: addr}
  end

  defp msg_data(%{iov: [data | _]}), do: data
  defp msg_data(_), do: <<>>
end
