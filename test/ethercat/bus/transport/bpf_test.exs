defmodule EtherCAT.Bus.Transport.BpfTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Bus.Transport
  alias EtherCAT.Bus.Transport.Bpf

  @moduletag :bpf

  @ethertype 0x88A4
  @broadcast <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>

  setup_all do
    interface = System.fetch_env!("ETHERCAT_BPF_INTERFACE")

    # A second port program on the same interface, built to receive what the machine itself sends:
    # it shows what the transport puts on the wire without a second interface to receive it on.
    source = Application.app_dir(:ethercat, "priv/bpf/ethercat_bpf.c")

    listener =
      Path.join(System.tmp_dir!(), "ethercat_bpf_listener_#{System.unique_integer([:positive])}")

    {_output, 0} =
      System.cmd("cc", ["-O2", "-DETHERCAT_BPF_SEE_SENT=1", "-o", listener, source],
        stderr_to_stdout: true
      )

    on_exit(fn -> File.rm(listener) end)
    %{interface: interface, listener: listener}
  end

  defp listen(%{interface: interface, listener: listener}) do
    port =
      Port.open({:spawn_executable, listener}, [
        :binary,
        :exit_status,
        {:packet, 2},
        args: [interface]
      ])

    assert_receive {^port, {:data, <<?R, _mac::binary-size(6)>>}}, 2_000
    port
  end

  # Writes a whole Ethernet frame on the interface, as another station might have sent it.
  defp inject(port, dst, src, ethertype, payload) do
    body = <<dst::binary, src::binary, ethertype::16, payload::binary>>
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
    listener = listen(context)
    {:ok, transport} = Bpf.open(interface: context.interface)
    payloads = for n <- 1..5, do: <<n, 0xEC, 0xA7>> <> :binary.copy(<<n>>, n * 20)

    for payload <- payloads do
      assert {:ok, tx_at} = Bpf.send(transport, payload)
      assert is_integer(tx_at)
    end

    for payload <- payloads do
      assert_receive {^listener, {:data, <<?F, frame::binary>>}}, 1_000
      <<dst::binary-size(6), src::binary-size(6), type::16, rest::binary>> = frame
      assert {dst, src, type} == {@broadcast, transport.src_mac, @ethertype}
      assert String.starts_with?(rest, payload)
      # A short frame is padded to the least an Ethernet frame may be.
      assert byte_size(frame) == max(60, 14 + byte_size(payload))
    end

    port = transport.port
    refute_receive {^port, _message}, 100
    Bpf.close(transport)
    Port.close(listener)
  end

  test "a frame that arrives is matched to its payload, and what is not EtherCAT never arrives",
       context do
    {:ok, transport} = Bpf.open(interface: context.interface)
    # With see-sent on, what one port program writes is what the other receives.
    {:ok, peer} = Bpf.open(interface: context.interface)
    sender = listen(context)
    port = transport.port
    station = <<0x02, 0x00, 0x5E, 0x10, 0x00, 0x01>>

    # The transport proper never receives what this machine sends: so it is tried on the listener's
    # kind of program, by reading that program's messages with the transport's own match.
    seeing = %{transport | port: sender}

    inject(peer.port, @broadcast, station, 0x0806, <<1, 2, 3, 4>>)
    inject(peer.port, @broadcast, station, @ethertype, <<0xAA, 0xBB, 0xCC>>)
    inject(peer.port, @broadcast, station, 0x8100, <<0, 5, @ethertype::16, 0xDD, 0xEE>>)
    inject(peer.port, @broadcast, <<0::48>>, @ethertype, <<0x11>>)

    assert_receive {^sender, {:data, <<?F, _::binary>>}} = first, 1_000
    assert {:ok, <<0xAA, 0xBB, 0xCC, _pad::binary>>, rx_at, ^station} = Bpf.match(seeing, first)
    assert is_integer(rx_at)

    # One VLAN tag is seen through.
    assert_receive {^sender, {:data, <<?F, _::binary>>}} = tagged, 1_000
    assert {:ok, <<0xDD, 0xEE, _pad::binary>>, _rx_at, ^station} = Bpf.match(seeing, tagged)

    # A frame from no station is dropped by the transport; the ARP frame never came this far.
    assert_receive {^sender, {:data, <<?F, _::binary>>}} = nobody, 1_000
    assert Bpf.match(seeing, nobody) == :ignore
    refute_receive {^sender, {:data, _frame}}, 100

    # What is not from the transport's own port is not its message.
    assert Bpf.match(transport, first) == :ignore
    assert Bpf.match(transport, :anything) == :ignore
    refute_receive {^port, _message}, 50

    Bpf.close(transport)
    Bpf.close(peer)
    Port.close(sender)
  end

  test "frames that wait are drained, and a port program that ends is an error", context do
    {:ok, transport} = Bpf.open(interface: context.interface)
    port = transport.port

    # Frames in the mailbox, as they are when they arrive with nobody waiting.
    for n <- 1..3, do: send(self(), {port, {:data, <<?F, n>>}})
    assert :ok = Bpf.drain(transport)
    refute_receive {^port, {:data, _frame}}, 20

    assert Bpf.match(transport, {port, {:data, <<?S, "Network is down">>}}) ==
             {:error, {:send_failed, "Network is down"}}

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-9", "#{os_pid}"])
    assert_receive {^port, {:exit_status, status}} = gone, 2_000
    assert Bpf.match(transport, gone) == {:error, {:bpf_port_exited, status}}
    assert Bpf.send(transport, <<1>>) == {:error, :closed}

    closed = Bpf.close(transport)
    refute Bpf.open?(closed)
  end
end
