defmodule EtherCAT.Bus.LinkMonitor do
  @moduledoc false

  alias EtherCAT.Bus.InterfaceInfo

  @af_netlink 16
  @netlink_route 0
  @rtnlgrp_link 1
  @rtm_newlink 16
  @ifla_ifname 3
  @poll_interval_ms 100
  @resync_interval_ms 5_000

  @type event ::
          {:ethercat_link, interface :: String.t(), old_up :: boolean(), new_up :: boolean()}

  @spec start_link(pid(), [String.t()], keyword()) :: {:ok, pid()}
  def start_link(owner, interfaces, opts \\ [])
      when is_pid(owner) and is_list(interfaces) and is_list(opts) do
    interval_ms = Keyword.get(opts, :poll_interval_ms, @poll_interval_ms)
    resync_interval_ms = Keyword.get(opts, :resync_interval_ms, @resync_interval_ms)

    pid =
      spawn_link(fn ->
        init(owner, Enum.uniq(interfaces), interval_ms, resync_interval_ms)
      end)

    {:ok, pid}
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

  defp init(owner, interfaces, poll_interval_ms, resync_interval_ms) do
    carriers = snapshot(interfaces)

    case open_netlink_socket() do
      {:ok, socket, {:select, select_ref}} ->
        loop(
          netlink_state(
            owner,
            interfaces,
            carriers,
            socket,
            select_ref,
            poll_interval_ms,
            resync_interval_ms
          )
        )

      {:ok, socket, {:ready, msg}} ->
        carriers = handle_netlink_message(msg, owner, carriers)

        case recv_ready_netlink(socket, owner, carriers) do
          {:ok, carriers, select_ref} ->
            loop(
              netlink_state(
                owner,
                interfaces,
                carriers,
                socket,
                select_ref,
                poll_interval_ms,
                resync_interval_ms
              )
            )

          {:fallback, carriers} ->
            :socket.close(socket)

            loop(%{
              owner: owner,
              interfaces: interfaces,
              carriers: carriers,
              mode: :poll,
              poll_interval_ms: poll_interval_ms,
              resync_interval_ms: resync_interval_ms
            })
        end

      {:error, _reason} ->
        loop(%{
          owner: owner,
          interfaces: interfaces,
          carriers: carriers,
          mode: :poll,
          poll_interval_ms: poll_interval_ms,
          resync_interval_ms: resync_interval_ms
        })
    end
  end

  defp loop(%{mode: :poll} = state) do
    receive do
      :stop ->
        :ok
    after
      state.poll_interval_ms ->
        next = snapshot(state.interfaces)
        notify_changes(state.owner, state.carriers, next)
        loop(%{state | carriers: next})
    end
  end

  defp loop(%{mode: {:netlink, socket, select_ref}} = state) do
    receive do
      :stop ->
        :socket.close(socket)
        :ok

      {:"$socket", ^socket, :select, ^select_ref} ->
        case recv_ready_netlink(socket, state.owner, state.carriers) do
          {:ok, carriers, next_select_ref} ->
            loop(%{state | carriers: carriers, mode: {:netlink, socket, next_select_ref}})

          {:fallback, carriers} ->
            :socket.close(socket)
            loop(%{state | carriers: carriers, mode: :poll})
        end
    after
      state.resync_interval_ms ->
        next = snapshot(state.interfaces)
        notify_changes(state.owner, state.carriers, next)
        loop(%{state | carriers: next})
    end
  end

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

          {:error, _} ->
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

  defp netlink_state(
         owner,
         interfaces,
         carriers,
         socket,
         select_ref,
         poll_interval_ms,
         resync_interval_ms
       ) do
    %{
      owner: owner,
      interfaces: interfaces,
      carriers: carriers,
      mode: {:netlink, socket, select_ref},
      poll_interval_ms: poll_interval_ms,
      resync_interval_ms: resync_interval_ms
    }
  end

  defp netlink_sockaddr(groups) do
    %{
      family: @af_netlink,
      addr: <<0::16-native, 0::32-native, groups::32-native>>
    }
  end
end
