defmodule EtherCAT.IntegrationSupport.RawSocketGuard do
  @moduledoc false

  @ethercat_proto "88a4"

  @spec assert_available!([String.t()], keyword()) :: :ok
  def assert_available!(interfaces, opts \\ []) do
    case ethercat_socket_owners(interfaces, opts) do
      {:ok, owners_by_interface} ->
        if map_size(owners_by_interface) == 0 do
          :ok
        else
          raise ArgumentError, format_conflict_message(owners_by_interface)
        end

      {:error, _reason} ->
        :ok
    end
  end

  @doc false
  @spec ethercat_socket_owners([String.t()], keyword()) ::
          {:ok, %{optional(String.t()) => [map()]}} | {:error, term()}
  def ethercat_socket_owners(interfaces, opts \\ []) do
    packet_table_reader = Keyword.get(opts, :packet_table_reader, &read_packet_table/0)
    ifindex_resolver = Keyword.get(opts, :ifindex_resolver, &ifindex_for/1)
    owner_lookup = Keyword.get(opts, :owner_lookup, &owners_for_inodes/1)

    with {:ok, packet_table} <- packet_table_reader.(),
         {:ok, ifindexes_by_interface} <- resolve_ifindexes(interfaces, ifindex_resolver) do
      packet_entries =
        packet_table
        |> parse_packet_table()
        |> Enum.filter(&(&1.proto == @ethercat_proto))

      target_entries =
        Enum.filter(packet_entries, fn entry ->
          Map.has_key?(ifindexes_by_interface, entry.ifindex)
        end)

      inodes = Enum.map(target_entries, & &1.inode)
      owners_by_inode = owner_lookup.(inodes)

      {:ok, group_conflicts(target_entries, ifindexes_by_interface, owners_by_inode)}
    end
  end

  defp read_packet_table do
    File.read("/proc/net/packet")
  end

  defp resolve_ifindexes(interfaces, ifindex_resolver) do
    interfaces
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn interface, {:ok, acc} ->
      case ifindex_resolver.(interface) do
        {:ok, ifindex} -> {:cont, {:ok, Map.put(acc, ifindex, interface)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ifindex_for(interface) do
    :net.if_name2index(String.to_charlist(interface))
  end

  defp parse_packet_table(packet_table) do
    packet_table
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(&parse_packet_line/1)
  end

  defp parse_packet_line(line) do
    case String.split(line, ~r/\s+/, trim: true) do
      [_sk, _ref_cnt, _type, proto, iface, _r, _rmem, _user, inode] ->
        case {Integer.parse(iface), Integer.parse(inode)} do
          {{ifindex, ""}, {inode, ""}} ->
            [%{proto: String.downcase(proto), ifindex: ifindex, inode: inode}]

          _other ->
            []
        end

      _other ->
        []
    end
  end

  defp owners_for_inodes(inodes) do
    wanted_inodes = MapSet.new(inodes)

    Path.wildcard("/proc/[0-9]*/fd/[0-9]*")
    |> Enum.reduce(%{}, fn fd_path, acc ->
      case File.read_link(fd_path) do
        {:ok, "socket:[" <> rest} ->
          case Integer.parse(String.trim_trailing(rest, "]")) do
            {inode, ""} ->
              if MapSet.member?(wanted_inodes, inode) do
                pid = fd_path |> Path.split() |> Enum.at(2)
                owner = %{pid: pid, command: process_command(pid)}
                Map.update(acc, inode, [owner], &[owner | &1])
              else
                acc
              end

            _other ->
              acc
          end

        _other ->
          acc
      end
    end)
    |> Enum.into(%{}, fn {inode, owners} ->
      unique_owners =
        owners
        |> Enum.uniq_by(& &1.pid)
        |> Enum.sort_by(&String.to_integer(&1.pid))

      {inode, unique_owners}
    end)
  end

  defp process_command(pid) do
    cmdline_path = "/proc/#{pid}/cmdline"

    case File.read(cmdline_path) do
      {:ok, ""} ->
        process_comm(pid)

      {:ok, cmdline} ->
        cmdline
        |> String.replace("\u0000", " ")
        |> String.trim()
        |> case do
          "" -> process_comm(pid)
          command -> command
        end

      {:error, _reason} ->
        process_comm(pid)
    end
  end

  defp process_comm(pid) do
    case File.read("/proc/#{pid}/comm") do
      {:ok, comm} -> String.trim(comm)
      {:error, _reason} -> "<unknown>"
    end
  end

  defp group_conflicts(entries, ifindexes_by_interface, owners_by_inode) do
    current_pid = System.pid()

    Enum.reduce(entries, %{}, fn entry, acc ->
      interface = Map.fetch!(ifindexes_by_interface, entry.ifindex)

      owners =
        owners_by_inode
        |> Map.get(entry.inode, [])
        |> Enum.reject(&(&1.pid == current_pid))

      if owners == [] do
        acc
      else
        details =
          Enum.map(owners, fn owner ->
            %{
              pid: owner.pid,
              command: owner.command,
              inode: entry.inode,
              proto: entry.proto
            }
          end)

        Map.update(acc, interface, details, &(&1 ++ details))
      end
    end)
    |> Enum.into(%{}, fn {interface, owners} ->
      unique_owners =
        owners
        |> Enum.uniq_by(fn owner -> {owner.pid, owner.inode} end)
        |> Enum.sort_by(fn owner -> String.to_integer(owner.pid) end)

      {interface, unique_owners}
    end)
  end

  defp format_conflict_message(owners_by_interface) do
    details =
      owners_by_interface
      |> Enum.sort_by(fn {interface, _owners} -> interface end)
      |> Enum.map_join("\n", fn {interface, owners} ->
        owners_text =
          Enum.map_join(owners, "\n", fn owner ->
            "  - pid=#{owner.pid} proto=0x#{owner.proto} inode=#{owner.inode} cmd=#{owner.command}"
          end)

        "#{interface}:\n#{owners_text}"
      end)

    """
    raw EtherCAT test interfaces are already in use by another local process:
    #{details}

    Stop the external EtherCAT master/simulator (for example a Livebook session) before running raw transport tests.
    """
    |> String.trim()
  end
end
