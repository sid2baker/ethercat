defmodule EtherCAT.Simulator.Transport.Raw.Endpoint do
  @moduledoc false

  use GenServer

  require Logger

  alias EtherCAT.Bus.Frame
  alias EtherCAT.Bus.InterfaceInfo
  alias EtherCAT.Simulator
  alias EtherCAT.Utils

  @af_packet 17
  @ethertype 0x88A4
  @broadcast_mac <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
  @echo_retention_ms 100

  @type ingress :: :primary | :secondary
  @type frame_envelope :: :plain | {:vlan, binary()}
  @type state :: %{
          socket: :socket.socket(),
          interface: String.t(),
          ifindex: non_neg_integer(),
          src_mac: <<_::48>>,
          ingress: ingress(),
          recent_tx_frames: [{binary(), integer()}],
          configured_response_delay_ms: non_neg_integer(),
          configured_response_delay_from_ingress: ingress() | :all,
          fault_response_delay_ms: non_neg_integer(),
          fault_response_delay_from_ingress: ingress() | :all
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, endpoint_name(Keyword.get(opts, :ingress, :primary)))

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, endpoint_name(Keyword.get(opts, :ingress, :primary)))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec endpoint_name(ingress()) :: atom()
  def endpoint_name(:primary), do: Module.concat(__MODULE__, Primary)
  def endpoint_name(:secondary), do: Module.concat(__MODULE__, Secondary)

  @spec info(GenServer.server()) :: {:ok, map()} | {:error, :not_found}
  def info(name \\ endpoint_name(:primary)) do
    GenServer.call(name, {:info})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, _reason -> {:error, :not_found}
  end

  @spec set_response_delay_fault(GenServer.server(), non_neg_integer(), ingress() | :all) ::
          :ok | {:error, :not_found}
  def set_response_delay_fault(name, delay_ms, from_ingress \\ :all)
      when is_integer(delay_ms) and delay_ms >= 0 and from_ingress in [:all, :primary, :secondary] do
    GenServer.call(name, {:set_response_delay_fault, delay_ms, from_ingress})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, _reason -> {:error, :not_found}
  end

  @spec clear_response_delay_fault(GenServer.server()) :: :ok | {:error, :not_found}
  def clear_response_delay_fault(name) do
    GenServer.call(name, {:clear_response_delay_fault})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, _reason -> {:error, :not_found}
  end

  @spec infos() :: {:ok, map()} | {:error, :not_found}
  def infos do
    endpoint_infos()
  end

  @impl true
  def init(opts) do
    interface = Keyword.fetch!(opts, :interface)
    ingress = Keyword.get(opts, :ingress, :primary)
    response_delay_ms = Keyword.get(opts, :response_delay_ms, 0)
    response_delay_from_ingress = Keyword.get(opts, :response_delay_from_ingress, :all)

    with {:ok, ifindex} <- :net.if_name2index(String.to_charlist(interface)),
         {:ok, src_mac} <- InterfaceInfo.mac_address(interface),
         {:ok, socket} <- :socket.open(@af_packet, :raw, {:raw, @ethertype}),
         :ok <- :socket.bind(socket, sockaddr_ll(ifindex)) do
      Logger.metadata(
        component: :simulator,
        transport: :raw_socket,
        interface: interface,
        ingress: ingress,
        ifindex: ifindex,
        response_delay_ms: response_delay_ms
      )

      :ok = arm_receive(socket)

      {:ok,
       %{
         socket: socket,
         interface: interface,
         ifindex: ifindex,
         src_mac: src_mac,
         ingress: ingress,
         recent_tx_frames: [],
         configured_response_delay_ms: response_delay_ms,
         configured_response_delay_from_ingress: response_delay_from_ingress,
         fault_response_delay_ms: 0,
         fault_response_delay_from_ingress: :all
       }}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:info}, _from, state) do
    {:reply,
     {:ok,
      %{
        interface: state.interface,
        ifindex: state.ifindex,
        ingress: state.ingress,
        recent_tx_frame_count: length(state.recent_tx_frames),
        configured_response_delay_ms: state.configured_response_delay_ms,
        configured_response_delay_from_ingress: state.configured_response_delay_from_ingress,
        response_delay_ms: effective_response_delay_ms(state),
        response_delay_from_ingress: effective_response_delay_from_ingress(state),
        delay_fault: delay_fault_info(state)
      }}, state}
  end

  def handle_call({:set_response_delay_fault, delay_ms, from_ingress}, _from, state) do
    {:reply, :ok,
     %{
       state
       | fault_response_delay_ms: delay_ms,
         fault_response_delay_from_ingress: from_ingress
     }}
  end

  def handle_call({:clear_response_delay_fault}, _from, state) do
    {:reply, :ok,
     %{
       state
       | fault_response_delay_ms: 0,
         fault_response_delay_from_ingress: :all
     }}
  end

  @impl true
  def handle_cast(
        {:send_response_frame, source_ingress, envelope, response_payload, padding,
         requester_mac},
        state
      ) do
    {:noreply,
     dispatch_response_frame(
       state,
       source_ingress,
       envelope,
       response_payload,
       padding,
       requester_mac
     )}
  end

  @impl true
  def handle_info({:"$socket", socket, :select, _}, %{socket: socket} = state) do
    {:noreply, receive_ready_frames(state)}
  end

  def handle_info(
        {:emit_response_frame, envelope, response_payload, padding, requester_mac},
        state
      ) do
    {:noreply, emit_response_frame(state, envelope, response_payload, padding, requester_mac)}
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

  defp process_raw_message(state, msg) do
    state = prune_recent_tx_frames(state)
    raw_frame = msg_data(msg)

    case pop_recent_tx_frame(state, raw_frame) do
      {:echo, updated} ->
        updated

      :miss ->
        with {:ok, envelope, payload, padding, requester_mac} <-
               split_ethercat_frame(raw_frame),
             {:ok, datagrams} <- Frame.decode(payload),
             :request <- classify_payload(datagrams),
             {:ok, response_datagrams, egress} <-
               Simulator.process_datagrams_with_routing(datagrams, ingress: state.ingress),
             {:ok, response_payload} <- Frame.encode(response_datagrams),
             {:ok, state} <-
               emit_or_forward_response(
                 state,
                 egress,
                 envelope,
                 response_payload,
                 padding,
                 requester_mac
               ) do
          state
        else
          :ignore ->
            state

          {:error, :no_response} ->
            state

          {:error, reason} ->
            Logger.warning(
              "[EtherCAT.Simulator.Transport.Raw.Endpoint] dropped invalid raw frame: #{inspect(reason)}",
              event: :invalid_frame_dropped,
              reason_kind: Utils.reason_kind(reason)
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
         <<_destination_mac::binary-size(6), source_mac::binary-size(6),
           @ethertype::big-unsigned-16, payload_with_padding::binary>>
       ) do
    with {:ok, payload, padding} <- split_payload_and_padding(payload_with_padding) do
      {:ok, :plain, payload, padding, source_mac}
    end
  end

  defp split_ethercat_frame(
         <<_destination_mac::binary-size(6), source_mac::binary-size(6), 0x8100::big-unsigned-16,
           vlan_tag::binary-size(2), @ethertype::big-unsigned-16, payload_with_padding::binary>>
       ) do
    with {:ok, payload, padding} <- split_payload_and_padding(payload_with_padding) do
      {:ok, {:vlan, vlan_tag}, payload, padding, source_mac}
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

  defp emit_or_forward_response(
         state,
         egress,
         envelope,
         response_payload,
         padding,
         requester_mac
       )

  defp emit_or_forward_response(
         %{ingress: ingress} = state,
         ingress,
         envelope,
         response_payload,
         padding,
         requester_mac
       ) do
    {:ok,
     dispatch_response_frame(state, ingress, envelope, response_payload, padding, requester_mac)}
  end

  defp emit_or_forward_response(state, egress, envelope, response_payload, padding, requester_mac) do
    if pid = Process.whereis(endpoint_name(egress)) do
      GenServer.cast(
        pid,
        {:send_response_frame, state.ingress, envelope, response_payload, padding, requester_mac}
      )

      {:ok, state}
    else
      {:error, :egress_unavailable}
    end
  end

  defp dispatch_response_frame(
         state,
         source_ingress,
         envelope,
         response_payload,
         padding,
         requester_mac
       ) do
    delay_ms = effective_response_delay_ms(state)

    cond do
      delay_ms <= 0 ->
        emit_response_frame(state, envelope, response_payload, padding, requester_mac)

      delay_response?(state, source_ingress) ->
        Process.send_after(
          self(),
          {:emit_response_frame, envelope, response_payload, padding, requester_mac},
          delay_ms
        )

        state

      true ->
        emit_response_frame(state, envelope, response_payload, padding, requester_mac)
    end
  end

  defp delay_response?(
         state,
         source_ingress
       )
       when source_ingress in [:primary, :secondary] do
    case effective_response_delay_from_ingress(state) do
      :all -> true
      expected_ingress -> expected_ingress == source_ingress
    end
  end

  defp delay_response?(_state, _source_ingress), do: false

  defp effective_response_delay_ms(%{fault_response_delay_ms: delay_ms}) when delay_ms > 0,
    do: delay_ms

  defp effective_response_delay_ms(%{configured_response_delay_ms: delay_ms}), do: delay_ms

  defp effective_response_delay_from_ingress(%{fault_response_delay_ms: delay_ms} = state)
       when delay_ms > 0,
       do: state.fault_response_delay_from_ingress

  defp effective_response_delay_from_ingress(state),
    do: state.configured_response_delay_from_ingress

  defp delay_fault_info(%{fault_response_delay_ms: 0}), do: nil

  defp delay_fault_info(state) do
    %{
      delay_ms: state.fault_response_delay_ms,
      from_ingress: state.fault_response_delay_from_ingress
    }
  end

  defp emit_response_frame(
         %{socket: socket, ifindex: ifindex} = state,
         envelope,
         response_payload,
         padding,
         requester_mac
       ) do
    # Use the requester's MAC as the source — real EtherCAT slaves don't
    # modify the Ethernet source MAC, so the frame returns with the
    # original sender's address.
    reply_frame =
      build_reply_frame(@broadcast_mac, requester_mac, envelope, response_payload, padding)

    case :socket.sendto(socket, reply_frame, sockaddr_ll(ifindex, @broadcast_mac)) do
      :ok -> remember_tx_frame(state, reply_frame)
      {:error, _reason} -> state
    end
  end

  defp build_reply_frame(destination_mac, source_mac, :plain, response_payload, padding) do
    <<destination_mac::binary, source_mac::binary, @ethertype::big-unsigned-16,
      response_payload::binary, padding::binary>>
  end

  defp build_reply_frame(
         destination_mac,
         source_mac,
         {:vlan, vlan_tag},
         response_payload,
         padding
       ) do
    <<destination_mac::binary, source_mac::binary, 0x8100::big-unsigned-16, vlan_tag::binary,
      @ethertype::big-unsigned-16, response_payload::binary, padding::binary>>
  end

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

  defp endpoint_infos do
    [:primary, :secondary]
    |> Enum.map(fn ingress -> {ingress, info(endpoint_name(ingress))} end)
    |> Enum.reduce(%{}, fn
      {ingress, {:ok, raw_info}}, acc -> Map.put(acc, ingress, raw_info)
      {_ingress, {:error, :not_found}}, acc -> acc
    end)
    |> case do
      endpoints when map_size(endpoints) > 0 -> {:ok, endpoints}
      _endpoints -> {:error, :not_found}
    end
  end
end
