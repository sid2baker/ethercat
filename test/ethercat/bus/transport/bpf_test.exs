defmodule EtherCAT.Bus.Transport.BpfTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Bus.Transport
  alias EtherCAT.Bus.Transport.Bpf

  @moduletag :bpf

  @ethertype 0x88A4
  @broadcast <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>

  setup_all do
    # Use an isolated feth pair, never a physical NIC or the runner's network.
    %{
      interface: System.fetch_env!("ETHERCAT_BPF_INTERFACE"),
      peer: System.fetch_env!("ETHERCAT_BPF_PEER_INTERFACE")
    }
  end

  # Writes a whole Ethernet frame through the peer, so it arrives on the
  # transport's real receive path with the production BIOCSSEESENT setting.
  defp inject(port, src, ethertype, payload) do
    body = <<@broadcast::binary, src::binary, ethertype::16, payload::binary>>
    Port.command(port, <<body::binary, 0::size(max(0, 60 - byte_size(body)))-unit(8)>>)
  end

  test "it is the raw transport of macOS" do
    assert Transport.raw() == Bpf
  end

  test "the port program is built once, and found again" do
    assert {:ok, program} = Bpf.program()
    assert File.regular?(program)
    %{mtime: built} = File.stat!(program, time: :posix)
    assert {:ok, ^program} = Bpf.program()
    assert %{mtime: ^built} = File.stat!(program, time: :posix)
  end

  test "it opens the interface with its hardware address, and closes", %{interface: interface} do
    assert {:ok, %Bpf{interface: ^interface, src_mac: <<_::48>> = mac} = transport} =
             Bpf.open(interface: interface)

    assert Bpf.open?(transport)
    assert Bpf.src_mac(transport) == mac
    assert Bpf.name(transport) == interface
    assert Bpf.interface(transport) == interface
    assert :ok = Bpf.set_active_once(transport)
    assert :ok = Bpf.rearm(transport)
    assert :ok = Bpf.drain(transport)

    closed = Bpf.close(transport)
    refute Bpf.open?(closed)
    assert Bpf.send(closed, <<1, 2, 3>>) == {:error, :closed}
    assert Bpf.close(closed) == closed
    assert Bpf.drain(closed) == :ok
    refute_receive {_port, {:exit_status, _status}}, 50
  end

  test "an interface that is not there is an error, with nothing left running" do
    assert {:error, {:bpf, reason}} = Bpf.open(interface: "nope0")
    assert reason =~ "nope0"
    refute_receive {_port, _message}, 50
  end

  test "a payload goes out as an EtherCAT frame, and the transport does not hear itself",
       context do
    {:ok, listener} = Bpf.open(interface: context.peer)
    {:ok, transport} = Bpf.open(interface: context.interface)
    payloads = for n <- 1..5, do: <<n, 0xEC, 0xA7>> <> :binary.copy(<<n>>, n * 20)
    listener_port = listener.port

    for payload <- payloads do
      assert {:ok, tx_at} = Bpf.send(transport, payload)
      assert is_integer(tx_at)
    end

    for payload <- payloads do
      assert_receive {^listener_port, {:data, <<?F, frame::binary>>}}, 2_000
      <<dst::binary-size(6), src::binary-size(6), type::16, rest::binary>> = frame
      assert {dst, src, type} == {@broadcast, transport.src_mac, @ethertype}
      assert String.starts_with?(rest, payload)
      assert byte_size(frame) == max(60, 14 + byte_size(payload))
    end

    port = transport.port
    refute_receive {^port, _message}, 100
    Bpf.close(transport)
    Bpf.close(listener)
  end

  test "incoming frames are filtered and matched, including VLAN and invalid sources", context do
    {:ok, transport} = Bpf.open(interface: context.interface)
    {:ok, peer} = Bpf.open(interface: context.peer)
    port = transport.port
    station = <<0x02, 0x00, 0x5E, 0x10, 0x00, 0x01>>

    inject(peer.port, station, 0x0806, <<1, 2, 3, 4>>)
    inject(peer.port, station, @ethertype, <<0xAA, 0xBB, 0xCC>>)
    inject(peer.port, station, 0x8100, <<0, 5, @ethertype::16, 0xDD, 0xEE>>)
    inject(peer.port, <<0::48>>, @ethertype, <<0x11>>)

    assert_receive {^port, {:data, <<?F, _::binary>>}} = first, 2_000

    assert {:ok, <<0xAA, 0xBB, 0xCC, _pad::binary>>, rx_at, ^station} =
             Bpf.match(transport, first)

    assert is_integer(rx_at)

    assert_receive {^port, {:data, <<?F, _::binary>>}} = tagged, 2_000
    assert {:ok, <<0xDD, 0xEE, _pad::binary>>, _rx_at, ^station} = Bpf.match(transport, tagged)

    # The ARP frame never passed the kernel filter; the zero source is rejected
    # by the transport rather than accepted as a station response.
    assert_receive {^port, {:data, <<?F, _::binary>>}} = nobody, 2_000
    assert Bpf.match(transport, nobody) == :ignore
    refute_receive {^port, {:data, _frame}}, 100
    assert Bpf.match(peer, first) == :ignore
    assert Bpf.match(transport, :anything) == :ignore

    Bpf.close(transport)
    Bpf.close(peer)
  end

  test "frames that wait are drained, and a port program that ends is an error", context do
    {:ok, transport} = Bpf.open(interface: context.interface)
    port = transport.port

    for n <- 1..3, do: send(self(), {port, {:data, <<?F, n>>}})
    assert :ok = Bpf.drain(transport)
    refute_receive {^port, {:data, _frame}}, 20

    assert Bpf.match(transport, {port, {:data, <<?S, "Network is down">>}}) ==
             {:error, {:send_failed, "Network is down"}}

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-9", "#{os_pid}"])
    assert_receive {^port, {:exit_status, status}} = gone, 2_000
    assert Bpf.match(transport, gone) == {:error, {:bpf_port_exited, status}}
    refute Bpf.open?(transport)
    assert Bpf.send(transport, <<1>>) == {:error, :closed}

    closed = Bpf.close(transport)
    refute Bpf.open?(closed)
  end
end
