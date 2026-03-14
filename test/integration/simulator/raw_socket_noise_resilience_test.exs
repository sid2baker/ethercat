defmodule EtherCAT.Integration.Simulator.RawSocketNoiseResilienceTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.IntegrationSupport.SimulatorRing

  @af_packet 17
  @ethertype 0x88A4

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    :ok
  end

  @tag :raw_socket
  test "raw transport reaches operational despite rogue EtherCAT frames on the wire" do
    noise_pid = start_noise_sender!()

    assert %{transport: :raw} = SimulatorRing.boot_operational!(transport: :raw)

    Expect.master_state(:operational)
    Expect.domain(:main, cycle_health: :healthy)
    Expect.slave(:coupler, station: 0x1000, al_state: :op)
    Expect.slave(:inputs, station: 0x1001, al_state: :op)
    Expect.slave(:outputs, station: 0x1002, al_state: :op)

    stop_noise_sender(noise_pid)
  end

  # -- noise sender -----------------------------------------------------------

  defp start_noise_sender! do
    interface = SimulatorRing.raw_simulator_interface()
    {:ok, ifindex} = :net.if_name2index(String.to_charlist(interface))
    {:ok, socket} = :socket.open(@af_packet, :raw, {:raw, @ethertype})

    addr = sockaddr_ll(ifindex)
    :ok = :socket.bind(socket, addr)

    pid =
      spawn_link(fn ->
        dest = sockaddr_ll(ifindex, <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>)
        noise_loop(socket, dest, 0)
      end)

    pid
  end

  defp stop_noise_sender(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      Process.exit(pid, :shutdown)
    end
  end

  defp noise_loop(socket, dest, idx) do
    frame = build_rogue_frame(rem(idx, 256))
    _ = :socket.sendto(socket, frame, dest)
    Process.sleep(2)
    noise_loop(socket, dest, idx + 1)
  end

  defp build_rogue_frame(idx) do
    # BRD datagram (cmd=7) with wkc=99 so the simulator classifies it as :ignore
    cmd = 7
    data = <<0, 0>>
    len = byte_size(data)
    <<len_field::big-unsigned-16>> = <<0::1, 0::1, 0::3, len::11>>

    datagram =
      <<cmd::8, idx::8, 0::32, len_field::little-16, 0::little-16, data::binary, 99::little-16>>

    dg_size = byte_size(datagram)
    <<ecat_hdr::big-unsigned-16>> = <<1::4, 0::1, dg_size::11>>
    ecat_payload = <<ecat_hdr::little-16, datagram::binary>>

    src_mac = <<0xBA, 0xAD, 0xF0, 0x0D, 0x00, 0x01>>
    broadcast = <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>

    frame_body = <<broadcast::binary, src_mac::binary, @ethertype::16-big, ecat_payload::binary>>
    pad_needed = max(0, 60 - byte_size(frame_body))
    <<frame_body::binary, 0::size(pad_needed)-unit(8)>>
  end

  defp sockaddr_ll(ifindex, mac \\ <<0::48>>) do
    mac_padded = if byte_size(mac) < 8, do: mac <> <<0::16>>, else: mac

    addr =
      <<@ethertype::16-big, ifindex::32-native, 0::16, 0::8, 6::8, mac_padded::binary-size(8)>>

    %{family: @af_packet, addr: addr}
  end
end
