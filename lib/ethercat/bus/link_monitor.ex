defmodule EtherCAT.Bus.LinkMonitor do
  @moduledoc false

  use GenServer

  alias EtherCAT.Bus.InterfaceInfo

  @af_netlink 16
  @netlink_route 0
  @rtnlgrp_link 1
  @rtm_newlink 16
  @ifla_ifname 3
  @poll_interval_ms 100
  @resync_interval_ms 5_000

  @type mode :: :netlink | :poll
  @type event ::
          {:ethercat_link, interface :: String.t(), old_up :: boolean(), new_up :: boolean()}

  @type state :: %{
          owner: pid(),
          interfaces: [String.t()],
          carriers: %{optional(String.t()) => boolean()},
          mode: mode(),
          notify_mode_changes?: boolean(),
          poll_interval_ms: pos_integer(),
          resync_interval_ms: pos_integer(),
          socket: :socket.socket() | nil,
          select_ref: reference() | nil
        }

  @spec start_link(pid(), [String.t()], keyword()) :: GenServer.on_start()
  def start_link(owner, interfaces, opts \\ [])
      when is_pid(owner) and is_list(interfaces) and is_list(opts) do
    GenServer.start_link(__MODULE__, {owner, Enum.uniq(interfaces), opts})
  end

  @spec mode(pid()) :: mode()
  def mode(pid) when is_pid(pid), do: GenServer.call(pid, :mode)

  @spec detect_mode() :: mode()
  def detect_mode do
    case open_netlink_socket() do
      {:ok, socket, _result} ->
        :socket.close(socket)
        :netlink

      {:error, _reason} ->
        :poll
    end
  end

  @spec snapshot([String.t()]) :: %{optional(String.t()) => boolean()}
  def snapshot(interfaces) do
    interfaces
    |> Enum.uniq()
    |> Map.new(fn interface -> {interface, InterfaceInfo.carrier_up?(interface)} end)
  end

  @spec decode_events(binary()) :: [{String.t(), boolean()}]
  def decode_events(data) when is_binary(data) do
    data
    |> decode_messages([])
    |> Enum.reverse()
  end

  @impl true
  def init({owner, interfaces, opts}) do
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @poll_interval_ms)
    resync_interval_ms = Keyword.get(opts, :resync_interval_ms, @resync_interval_ms)

    state = %{
      owner: owner,
      interfaces: interfaces,
      carriers: snapshot(interfaces),
      mode: :poll,
      notify_mode_changes?: false,
      poll_interval_ms: poll_interval_ms,
      resync_interval_ms: resync_interval_ms,
      socket: nil,
      select_ref: nil
    }

    {:ok, initialize_mode(state)}
  end

  @impl true
  def handle_call(:mode, _from, state) do
    {:reply, state.mode, state}
  end

  @impl true
  def handle_info(:poll_tick, %{mode: :poll} = state) do
    next = snapshot(state.interfaces)
    notify_changes(state.owner, state.carriers, next)
    schedule_poll(state.poll_interval_ms)
    {:noreply, %{state | carriers: next}}
  end

  def handle_info(:poll_tick, state), do: {:noreply, state}

  @impl true
  def handle_info(:resync, %{mode: :netlink} = state) do
    next = snapshot(state.interfaces)
    notify_changes(state.owner, state.carriers, next)
    schedule_resync(state.resync_interval_ms)
    {:noreply, %{state | carriers: next}}
  end

  def handle_info(:resync, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:"$socket", socket, :select, select_ref},
        %{mode: :netlink, socket: socket, select_ref: select_ref} = state
      ) do
    case recv_ready_netlink(socket, state.owner, state.carriers) do
      {:ok, carriers, next_select_ref} ->
        {:noreply, %{state | carriers: carriers, select_ref: next_select_ref}}

      {:fallback, carriers} ->
        :socket.close(socket)

        {:noreply,
         switch_mode(%{state | carriers: carriers, socket: nil, select_ref: nil}, :poll)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{socket: socket}) when not is_nil(socket) do
    :socket.close(socket)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp initialize_mode(state) do
    case open_netlink_socket() do
      {:ok, socket, {:select, select_ref}} ->
        state
        |> Map.put(:socket, socket)
        |> Map.put(:select_ref, select_ref)
        |> switch_mode(:netlink)

      {:ok, socket, {:ready, msg}} ->
        carriers = handle_netlink_message(msg, state.owner, state.carriers)

        case recv_ready_netlink(socket, state.owner, carriers) do
          {:ok, carriers, select_ref} ->
            state
            |> Map.put(:carriers, carriers)
            |> Map.put(:socket, socket)
            |> Map.put(:select_ref, select_ref)
            |> switch_mode(:netlink)

          {:fallback, carriers} ->
            :socket.close(socket)
            switch_mode(%{state | carriers: carriers}, :poll)
        end

      {:error, _reason} ->
        switch_mode(state, :poll)
    end
  end

  defp switch_mode(
         %{owner: owner, mode: old_mode, notify_mode_changes?: true} = state,
         new_mode
       )
       when old_mode != new_mode do
    send(owner, {:ethercat_link_monitor_mode, old_mode, new_mode})

    state =
      case new_mode do
        :poll ->
          schedule_poll(state.poll_interval_ms)
          %{state | mode: :poll}

        :netlink ->
          schedule_resync(state.resync_interval_ms)
          %{state | mode: :netlink}
      end

    state
  end

  defp switch_mode(state, :poll) do
    schedule_poll(state.poll_interval_ms)
    %{state | mode: :poll, notify_mode_changes?: true}
  end

  defp switch_mode(state, :netlink) do
    schedule_resync(state.resync_interval_ms)
    %{state | mode: :netlink, notify_mode_changes?: true}
  end

  defp schedule_poll(interval_ms), do: Process.send_after(self(), :poll_tick, interval_ms)
  defp schedule_resync(interval_ms), do: Process.send_after(self(), :resync, interval_ms)

  defp open_netlink_socket do
    case :socket.open(@af_netlink, :raw, @netlink_route) do
      {:ok, socket} ->
        case :socket.bind(socket, netlink_sockaddr(@rtnlgrp_link)) do
          :ok ->
            case arm_receive(socket) do
              {:ok, result} ->
                {:ok, socket, result}

              {:error, reason} ->
                :socket.close(socket)
                {:error, reason}
            end

          {:error, reason} ->
            :socket.close(socket)
            {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp recv_ready_netlink(socket, owner, carriers) do
    case :socket.recvmsg(socket, 0, 0, :nowait) do
      {:ok, msg} ->
        recv_ready_netlink(socket, owner, handle_netlink_message(msg, owner, carriers))

      {:select, _} ->
        case arm_receive(socket) do
          {:ok, {:select, select_ref}} ->
            {:ok, carriers, select_ref}

          {:ok, {:ready, msg}} ->
            recv_ready_netlink(socket, owner, handle_netlink_message(msg, owner, carriers))

          {:error, _reason} ->
            {:fallback, carriers}
        end

      {:error, _reason} ->
        {:fallback, carriers}
    end
  end

  defp arm_receive(socket) do
    select_ref = make_ref()

    case :socket.recvmsg(socket, 0, 0, select_ref) do
      {:select, {:select_info, _, ^select_ref}} -> {:ok, {:select, select_ref}}
      {:select, _other} -> {:ok, {:select, select_ref}}
      {:ok, msg} -> {:ok, {:ready, msg}}
      {:error, _reason} = error -> error
    end
  end

  defp handle_netlink_message(%{iov: [data | _]}, owner, carriers) when is_binary(data) do
    Enum.reduce(decode_events(data), carriers, fn {interface, new_up}, acc ->
      if Map.has_key?(acc, interface) do
        old_up = Map.fetch!(acc, interface)

        if old_up != new_up do
          send(owner, {:ethercat_link, interface, old_up, new_up})
        end

        Map.put(acc, interface, new_up)
      else
        acc
      end
    end)
  end

  defp handle_netlink_message(_msg, _owner, carriers), do: carriers

  defp notify_changes(owner, old_carriers, new_carriers) do
    Enum.each(new_carriers, fn {interface, new_up} ->
      old_up = Map.get(old_carriers, interface, new_up)

      if old_up != new_up do
        send(owner, {:ethercat_link, interface, old_up, new_up})
      end
    end)
  end

  defp decode_messages(<<>>, acc), do: acc

  defp decode_messages(
         <<len::32-native, type::16-native, _flags::16-native, _seq::32-native, _pid::32-native,
           rest::binary>>,
         acc
       )
       when len >= 16 and len - 16 <= byte_size(rest) do
    payload_len = len - 16
    aligned_len = align4(len)
    skip_len = max(aligned_len - 16, 0)

    <<payload::binary-size(payload_len), remaining::binary>> = rest

    next_remaining =
      if skip_len > payload_len do
        <<_padding::binary-size(skip_len - payload_len), tail::binary>> = remaining
        tail
      else
        remaining
      end

    next_acc =
      case type do
        @rtm_newlink ->
          case decode_newlink(payload) do
            {:ok, event} -> [event | acc]
            :ignore -> acc
          end

        _other ->
          acc
      end

    decode_messages(next_remaining, next_acc)
  end

  defp decode_messages(_data, acc), do: acc

  defp decode_newlink(
         <<_family::8, _pad::8, _type::16-native, _index::32-native, flags::32-native,
           _change::32-native, attrs::binary>>
       ) do
    case decode_ifname(attrs) do
      nil ->
        :ignore

      ifname ->
        {:ok, {ifname, lower_up?(flags)}}
    end
  end

  defp decode_newlink(_payload), do: :ignore

  defp decode_ifname(attrs), do: decode_ifname(attrs, nil)

  defp decode_ifname(<<>>, ifname), do: ifname

  defp decode_ifname(<<len::16-native, type::16-native, rest::binary>>, ifname)
       when len >= 4 and len - 4 <= byte_size(rest) do
    value_len = len - 4
    aligned_len = align4(len)
    skip_len = max(aligned_len - 4, 0)

    <<value::binary-size(value_len), remaining::binary>> = rest

    next_remaining =
      if skip_len > value_len do
        <<_padding::binary-size(skip_len - value_len), tail::binary>> = remaining
        tail
      else
        remaining
      end

    next_ifname =
      case type do
        @ifla_ifname -> trim_null(value)
        _other -> ifname
      end

    decode_ifname(next_remaining, next_ifname)
  end

  defp decode_ifname(_attrs, ifname), do: ifname

  defp lower_up?(flags) do
    <<_::size(15), lower_up::size(1), _::size(16)>> =
      <<flags::unsigned-integer-size(32)>>

    lower_up == 1
  end

  defp trim_null(value) do
    value
    |> :binary.split(<<0>>, [:global])
    |> List.first()
  end

  defp align4(len), do: div(len + 3, 4) * 4

  defp netlink_sockaddr(groups) do
    %{
      family: @af_netlink,
      addr: <<0::16-native, 0::32-native, groups::32-native>>
    }
  end
end
