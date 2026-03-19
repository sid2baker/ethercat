defmodule EtherCAT.IntegrationSupport.RawSocketGuardTest do
  use ExUnit.Case, async: true

  alias EtherCAT.IntegrationSupport.RawSocketGuard

  test "reports EtherCAT packet socket owners on the requested interfaces only" do
    packet_table = """
    sk               RefCnt Type Proto  Iface R Rmem   User   Inode
    0000000000000000 3      2    88A4   7     1 0      0      101
    0000000000000000 3      2    0806   7     1 0      0      202
    0000000000000000 3      2    88a4   8     1 0      0      303
    """

    assert {:ok,
            %{
              "veth-m0" => [%{pid: "123", command: "beam.smp -- livebook", inode: 101}],
              "veth-s0" => [%{pid: "456", command: "beam.smp -- iex", inode: 303}]
            }} =
             RawSocketGuard.ethercat_socket_owners(
               ["veth-m0", "veth-s0"],
               packet_table_reader: fn -> {:ok, packet_table} end,
               ifindex_resolver: fn
                 "veth-m0" -> {:ok, 7}
                 "veth-s0" -> {:ok, 8}
               end,
               owner_lookup: fn [101, 303] ->
                 %{
                   101 => [%{pid: "123", command: "beam.smp -- livebook"}],
                   303 => [%{pid: "456", command: "beam.smp -- iex"}]
                 }
               end
             )
  end

  test "ignores non-EtherCAT packet sockets" do
    packet_table = """
    sk               RefCnt Type Proto  Iface R Rmem   User   Inode
    0000000000000000 3      2    0806   7     1 0      0      101
    0000000000000000 3      2    88B5   7     1 0      0      202
    """

    assert {:ok, %{}} =
             RawSocketGuard.ethercat_socket_owners(
               ["veth-m0"],
               packet_table_reader: fn -> {:ok, packet_table} end,
               ifindex_resolver: fn "veth-m0" -> {:ok, 7} end,
               owner_lookup: fn [] -> %{} end
             )
  end

  test "assert_available! raises with a clear conflict message" do
    packet_table = """
    sk               RefCnt Type Proto  Iface R Rmem   User   Inode
    0000000000000000 3      2    88a4   7     1 0      0      101
    """

    assert_raise ArgumentError,
                 ~r/raw EtherCAT test interfaces are already in use.*veth-m0.*beam\.smp -- livebook/s,
                 fn ->
                   RawSocketGuard.assert_available!(
                     ["veth-m0"],
                     packet_table_reader: fn -> {:ok, packet_table} end,
                     ifindex_resolver: fn "veth-m0" -> {:ok, 7} end,
                     owner_lookup: fn [101] ->
                       %{101 => [%{pid: "123", command: "beam.smp -- livebook"}]}
                     end
                   )
                 end
  end
end
