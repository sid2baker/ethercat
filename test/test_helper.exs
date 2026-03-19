defmodule EtherCAT.TestHelper do
  @af_packet 17
  @ethertype 0x88A4

  def raw_socket_excludes do
    exclusion_for(
      :raw_socket,
      "raw simulator",
      [
        System.get_env("ETHERCAT_RAW_MASTER_INTERFACE") || "veth-m0",
        System.get_env("ETHERCAT_RAW_SIMULATOR_INTERFACE") || "veth-s0"
      ]
    )
  end

  def raw_socket_redundant_excludes do
    exclusion_for(:raw_socket_redundant, "redundant raw simulator", redundant_raw_interfaces())
  end

  def raw_socket_redundant_toggle_excludes do
    case exclusion_for(
           :raw_socket_redundant,
           "redundant raw simulator",
           redundant_raw_interfaces(),
           warn?: false
         ) do
      [] ->
        if can_toggle_redundant_raw_links?() do
          []
        else
          warn_toggle_excluded()
          [:raw_socket_redundant_toggle]
        end

      _other ->
        [:raw_socket_redundant_toggle]
    end
  end

  defp redundant_raw_interfaces do
    [
      System.get_env("ETHERCAT_REDUNDANT_RAW_MASTER_PRIMARY_INTERFACE") || "veth-m0",
      System.get_env("ETHERCAT_REDUNDANT_RAW_SIMULATOR_PRIMARY_INTERFACE") || "veth-s0",
      System.get_env("ETHERCAT_REDUNDANT_RAW_MASTER_SECONDARY_INTERFACE") || "veth-m1",
      System.get_env("ETHERCAT_REDUNDANT_RAW_SIMULATOR_SECONDARY_INTERFACE") || "veth-s1"
    ]
  end

  defp exclusion_for(tag, label, interfaces, opts \\ []) do
    case interface_statuses(interfaces) do
      {[], []} ->
        []

      {missing, unavailable} ->
        if Keyword.get(opts, :warn?, true) do
          warn_excluded(tag, label, missing, unavailable)
        end

        [tag]
    end
  end

  defp interface_statuses(interfaces) do
    Enum.reduce(interfaces, {[], []}, fn interface, {missing, unavailable} ->
      case raw_socket_interface_status(interface) do
        :ok -> {missing, unavailable}
        :missing -> {[interface | missing], unavailable}
        :unavailable -> {missing, [interface | unavailable]}
      end
    end)
    |> then(fn {missing, unavailable} -> {Enum.reverse(missing), Enum.reverse(unavailable)} end)
  end

  defp raw_socket_interface_status(interface) do
    if File.exists?("/sys/class/net/#{interface}") do
      case :net.if_name2index(String.to_charlist(interface)) do
        {:ok, ifindex} ->
          with {:ok, socket} <- :socket.open(@af_packet, :raw, {:raw, @ethertype}),
               :ok <- :socket.bind(socket, sockaddr_ll(ifindex)) do
            :socket.close(socket)
            :ok
          else
            _ -> :unavailable
          end

        {:error, _reason} ->
          :unavailable
      end
    else
      :missing
    end
  end

  defp sockaddr_ll(ifindex) do
    %{
      family: @af_packet,
      addr: <<@ethertype::16-big, ifindex::32-native, 0::16, 0::8, 6::8, 0::64>>
    }
  end

  defp warn_excluded(tag, label, missing, unavailable) do
    parts =
      [
        "warning: excluding #{inspect(tag)} tests for #{label}.",
        missing_interfaces_message(missing),
        unavailable_interfaces_message(unavailable)
      ]
      |> Enum.reject(&is_nil/1)

    IO.puts(:stderr, Enum.join(parts, "\n"))
  end

  defp missing_interfaces_message([]), do: nil

  defp missing_interfaces_message(missing) do
    pair_commands =
      missing
      |> missing_veth_pairs()
      |> Enum.map(&creation_commands/1)

    commands =
      case pair_commands do
        [] ->
          [
            "  create the required veth pair(s) so these interfaces exist before running `mix test`."
          ]

        _ ->
          pair_commands
      end
      |> Enum.join("\n")

    [
      "missing interfaces: #{Enum.join(missing, ", ")}",
      "create them with:",
      commands
    ]
    |> Enum.join("\n")
  end

  defp unavailable_interfaces_message([]), do: nil

  defp unavailable_interfaces_message(unavailable) do
    "interfaces present but raw bind failed: #{Enum.join(unavailable, ", ")}"
  end

  defp missing_veth_pairs(missing) do
    missing
    |> Enum.filter(&String.starts_with?(&1, "veth-"))
    |> Enum.group_by(fn interface ->
      interface
      |> String.trim_leading("veth-")
      |> String.slice(1..-1//1)
    end)
    |> Enum.map(fn {_suffix, pair_members} ->
      case Enum.sort(pair_members) do
        ["veth-m" <> _ = master, "veth-s" <> _ = simulator] -> {master, simulator}
        _other -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp creation_commands({master, simulator}) do
    [
      "  sudo ip link add #{master} type veth peer name #{simulator}",
      "  sudo ip link set #{master} up",
      "  sudo ip link set #{simulator} up"
    ]
    |> Enum.join("\n")
  end

  defp can_toggle_redundant_raw_links? do
    System.find_executable("ip") &&
      (running_as_root?() or passwordless_sudo_available?())
  end

  defp running_as_root? do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {"0\n", 0} -> true
      _other -> false
    end
  end

  defp passwordless_sudo_available? do
    case System.find_executable("sudo") do
      nil ->
        false

      _sudo ->
        case System.cmd("sudo", ["-n", "true"], stderr_to_stdout: true) do
          {_output, 0} -> true
          _other -> false
        end
    end
  end

  defp warn_toggle_excluded do
    IO.puts(
      :stderr,
      "warning: excluding :raw_socket_redundant_toggle tests because `ip link set` is not available without interactive privileges."
    )
  end
end

ExUnit.start(
  capture_log: true,
  formatters: [ExUnit.CLIFormatter, EtherCAT.TestProgressFormatter],
  exclude:
    [:hardware] ++
      EtherCAT.TestHelper.raw_socket_excludes() ++
      EtherCAT.TestHelper.raw_socket_redundant_excludes() ++
      EtherCAT.TestHelper.raw_socket_redundant_toggle_excludes()
)
