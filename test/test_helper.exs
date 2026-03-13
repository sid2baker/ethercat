defmodule EtherCAT.TestHelper do
  @af_packet 17
  @ethertype 0x88A4

  def raw_socket_excludes do
    if raw_socket_available?() do
      []
    else
      [:raw_socket]
    end
  end

  defp raw_socket_available? do
    master_interface = System.get_env("ETHERCAT_RAW_MASTER_INTERFACE") || "veth-m0"
    simulator_interface = System.get_env("ETHERCAT_RAW_SIMULATOR_INTERFACE") || "veth-s0"

    Enum.all?([master_interface, simulator_interface], &raw_socket_interface_available?/1)
  end

  defp raw_socket_interface_available?(interface) do
    if File.exists?("/sys/class/net/#{interface}") do
      case :net.if_name2index(String.to_charlist(interface)) do
        {:ok, ifindex} ->
          with {:ok, socket} <- :socket.open(@af_packet, :raw, {:raw, @ethertype}),
               :ok <- :socket.bind(socket, sockaddr_ll(ifindex)) do
            :socket.close(socket)
            true
          else
            _ -> false
          end

        {:error, _reason} ->
          false
      end
    else
      false
    end
  end

  defp sockaddr_ll(ifindex) do
    %{
      family: @af_packet,
      addr: <<@ethertype::16-big, ifindex::32-native, 0::16, 0::8, 6::8, 0::64>>
    }
  end
end

ExUnit.start(exclude: [:hardware] ++ EtherCAT.TestHelper.raw_socket_excludes())
