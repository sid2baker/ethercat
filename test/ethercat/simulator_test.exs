defmodule EtherCAT.SimulatorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias EtherCAT.Bus.Datagram
  alias EtherCAT.Bus.Frame
  alias EtherCAT.Bus.Transport.RawSocket
  alias EtherCAT.Driver.EK1100
  import EtherCAT.Integration.Assertions
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.Slave, as: SimSlave
  alias EtherCAT.Simulator.Transport.Raw.Endpoint
  alias EtherCAT.Simulator.Transport.Raw
  alias EtherCAT.Simulator.Transport.Raw.Fault, as: RawFault
  alias EtherCAT.Simulator.Transport.Udp.Fault, as: UdpFault

  @loopback {127, 0, 0, 1}
  @raw_loopback_interface "lo"
  @af_packet 17
  @ethertype 0x88A4
  @sol_packet 263
  @packet_ignore_outgoing 23
  @broadcast_mac <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
  @test_source_mac <<0x02, 0x00, 0x00, 0x00, 0x00, 0x01>>
  @min_frame_size 60

  setup do
    _ = Simulator.stop()

    on_exit(fn ->
      _ = Simulator.stop()
    end)

    :ok
  end

  test "stop/0 shuts down the supervised simulator runtime" do
    assert {:ok, _supervisor} =
             Simulator.start(devices: [], udp: [ip: @loopback, port: 0])

    assert {:ok, info} = Simulator.info()
    assert %{udp: %{port: port}} = info
    assert is_integer(port)
    assert port > 0

    assert :ok = Simulator.stop()
    assert {:error, :not_found} = Simulator.info()
  end

  test "stop/0 shuts down the default unsupervised simulator runtime" do
    assert {:ok, _pid} = Simulator.start_link(devices: [])
    assert {:ok, _info} = Simulator.info()

    assert :ok = Simulator.stop()
    assert {:error, :not_found} = Simulator.info()
  end

  test "child_spec/1 uses the supervised runtime and honors udp opts" do
    assert {:ok, supervisor} =
             Supervisor.start_link(
               [{Simulator, devices: [], udp: [ip: @loopback, port: 0]}],
               strategy: :one_for_one
             )

    assert {:ok, %{udp: %{port: port}}} = Simulator.info()
    assert is_integer(port)
    assert port > 0

    assert :ok = Supervisor.stop(supervisor)
    assert {:error, :not_found} = Simulator.info()
  end

  @tag :raw_socket
  test "raw transport enables PACKET_IGNORE_OUTGOING" do
    assert {:ok, sock} = RawSocket.open(interface: @raw_loopback_interface)

    on_exit(fn ->
      _ = RawSocket.close(sock)
    end)

    assert {:ok, true} =
             :socket.getopt_native(
               sock.raw,
               {@sol_packet, @packet_ignore_outgoing},
               :boolean
             )
  end

  @tag :raw_socket
  test "child_spec/1 uses the supervised runtime and honors raw opts" do
    assert {:ok, supervisor} =
             Supervisor.start_link(
               [{Simulator, devices: [], raw: [interface: @raw_loopback_interface]}],
               strategy: :one_for_one
             )

    assert {:ok,
            %{
              raw: %{
                mode: :single,
                primary: %{interface: @raw_loopback_interface, ifindex: ifindex}
              }
            }} =
             Simulator.info()

    assert is_integer(ifindex)
    assert ifindex > 0

    assert :ok = Supervisor.stop(supervisor)
    assert {:error, :not_found} = Simulator.info()
  end

  @tag :raw_socket
  test "supervised runtime can expose primary and secondary raw endpoints" do
    assert {:ok, supervisor} =
             Supervisor.start_link(
               [
                 {Simulator,
                  devices: [],
                  raw: [
                    primary: [interface: @raw_loopback_interface],
                    secondary: [interface: @raw_loopback_interface]
                  ],
                  topology: :redundant}
               ],
               strategy: :one_for_one
             )

    assert {:ok,
            %{
              raw: %{
                mode: :redundant,
                primary: %{interface: @raw_loopback_interface, ingress: :primary},
                secondary: %{interface: @raw_loopback_interface, ingress: :secondary}
              }
            }} = Simulator.info()

    assert :ok = Supervisor.stop(supervisor)
    assert {:error, :not_found} = Simulator.info()
  end

  test "public simulator api returns not_found instead of exiting when no simulator is running" do
    assert {:error, :not_found} = Simulator.process_datagrams([])
    assert {:error, :not_found} = Simulator.clear_faults()
    assert {:error, :not_found} = Simulator.signals(:coupler)
    assert {:error, :not_found} = Simulator.get_value(:coupler, :missing)
    assert {:error, :not_found} = Simulator.output_image(:coupler)
    assert {:error, :not_found} = Simulator.connections()
    assert {:error, :not_found} = Simulator.connect({:a, :out}, {:b, :in})
    assert {:error, :not_found} = Simulator.subscribe(:coupler)
  end

  test "public simulator api distinguishes a server crash from not_found" do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    assert {:ok, _pid} = Simulator.start_link(devices: [])

    capture_log(fn ->
      assert {:error, {:server_exit, _reason}} = Simulator.process_datagrams(:invalid)
    end)

    assert {:error, :not_found} = Simulator.info()
  end

  test "setup cleanup can stop the supervised simulator runtime" do
    assert {:ok, _supervisor} =
             Simulator.start(devices: [], udp: [ip: @loopback, port: 0])

    assert {:ok, %{udp: %{port: port}}} = Simulator.info()
    assert is_integer(port)
    assert port > 0
  end

  test "info/0 reports queued exchange faults" do
    assert {:ok, _pid} = Simulator.start_link(devices: [])

    assert :ok =
             Simulator.inject_fault(Fault.script([Fault.drop_responses(), Fault.wkc_offset(-1)]))

    assert {:ok, %{next_fault: {:next_exchange, :drop_responses}, pending_faults: pending_faults}} =
             Simulator.info()

    assert pending_faults == [:drop_responses, {:wkc_offset, -1}]
  end

  test "fault builders provide readable descriptions for tooling" do
    assert Fault.describe(Fault.disconnect(:outputs) |> Fault.next(3)) ==
             "next 3 exchanges disconnect outputs"

    assert Fault.describe(
             Fault.mailbox_abort(:mailbox, 0x2003, 0x01, 0x0800_0000, stage: :upload_segment)
           ) ==
             "mailbox abort 0x08000000 on mailbox for 0x2003:0x01 during upload_segment"

    assert Fault.describe(
             Fault.retreat_to_safeop(:outputs)
             |> Fault.after_ms(250)
             |> Fault.after_milestone(Fault.healthy_exchanges(2))
           ) ==
             "after 2 healthy exchanges after 250ms retreat outputs to SAFEOP"

    assert UdpFault.describe(UdpFault.truncate() |> UdpFault.next(2)) ==
             "next 2 UDP replies truncate"

    assert RawFault.describe(
             RawFault.delay_response(200, endpoint: :secondary, from_ingress: :primary)
           ) ==
             "delay secondary raw responses from primary ingress by 200ms"
  end

  @tag :raw_socket
  test "raw transport exposes mode-aware info and delay-response faults" do
    assert {:ok, supervisor} =
             Supervisor.start_link(
               [{Simulator, devices: [], raw: [interface: @raw_loopback_interface]}],
               strategy: :one_for_one
             )

    assert {:ok,
            %{
              mode: :single,
              primary: %{
                configured_response_delay_ms: 0,
                response_delay_ms: 0,
                response_delay_from_ingress: :all,
                delay_fault: nil
              }
            }} = Raw.info()

    assert :ok = Raw.inject_fault(RawFault.delay_response(75))

    assert {:ok,
            %{
              mode: :single,
              primary: %{
                configured_response_delay_ms: 0,
                response_delay_ms: 75,
                response_delay_from_ingress: :all,
                delay_fault: %{delay_ms: 75, from_ingress: :all}
              }
            }} = Raw.info()

    assert {:error, :invalid_fault} =
             Raw.inject_fault(RawFault.delay_response(75, endpoint: :secondary))

    assert :ok = Raw.clear_faults()

    assert {:ok,
            %{
              mode: :single,
              primary: %{
                configured_response_delay_ms: 0,
                response_delay_ms: 0,
                response_delay_from_ingress: :all,
                delay_fault: nil
              }
            }} = Raw.info()

    assert :ok = Supervisor.stop(supervisor)
  end

  @tag :raw_socket
  test "raw clear_faults preserves configured response delay" do
    assert {:ok, supervisor} =
             Supervisor.start_link(
               [
                 {Simulator,
                  devices: [],
                  raw: [
                    interface: @raw_loopback_interface,
                    response_delay_ms: 30,
                    response_delay_from_ingress: :primary
                  ]}
               ],
               strategy: :one_for_one
             )

    assert {:ok,
            %{
              mode: :single,
              primary: %{
                configured_response_delay_ms: 30,
                configured_response_delay_from_ingress: :primary,
                response_delay_ms: 30,
                response_delay_from_ingress: :primary,
                delay_fault: nil
              }
            }} = Raw.info()

    assert :ok = Raw.inject_fault(RawFault.delay_response(75, from_ingress: :secondary))

    assert {:ok,
            %{
              mode: :single,
              primary: %{
                configured_response_delay_ms: 30,
                configured_response_delay_from_ingress: :primary,
                response_delay_ms: 75,
                response_delay_from_ingress: :secondary,
                delay_fault: %{delay_ms: 75, from_ingress: :secondary}
              }
            }} = Raw.info()

    assert :ok = Raw.clear_faults()

    assert {:ok,
            %{
              mode: :single,
              primary: %{
                configured_response_delay_ms: 30,
                configured_response_delay_from_ingress: :primary,
                response_delay_ms: 30,
                response_delay_from_ingress: :primary,
                delay_fault: nil
              }
            }} = Raw.info()

    assert :ok = Supervisor.stop(supervisor)
  end

  @tag :raw_socket
  test "single raw runtime preserves a custom endpoint name" do
    custom_name = :"raw_endpoint_#{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, supervisor} =
             Supervisor.start_link(
               [
                 {Simulator,
                  devices: [], raw: [interface: @raw_loopback_interface, name: custom_name]}
               ],
               strategy: :one_for_one
             )

    assert is_pid(Process.whereis(custom_name))

    assert {:ok, %{interface: @raw_loopback_interface, ingress: :primary}} =
             Endpoint.info(custom_name)

    assert :ok = Supervisor.stop(supervisor)
  end

  test "info/0 reports active logical wkc offsets" do
    assert {:ok, _pid} = Simulator.start_link(devices: [])
    assert :ok = Simulator.inject_fault(Fault.logical_wkc_offset(:coupler, -1))

    assert {:ok, %{logical_wkc_offsets: %{coupler: -1}}} = Simulator.info()
  end

  test "info/0 reports active command wkc offsets" do
    assert {:ok, _pid} = Simulator.start_link(devices: [])
    assert :ok = Simulator.inject_fault(Fault.command_wkc_offset(:fprd, -1))

    assert {:ok, %{command_wkc_offsets: %{fprd: -1}}} = Simulator.info()
  end

  test "info/0 reports delayed scheduled faults and drains them when due" do
    assert {:ok, _pid} = Simulator.start_link(devices: [])

    assert :ok =
             Simulator.inject_fault(Fault.script([Fault.drop_responses()]) |> Fault.after_ms(50))

    assert {:ok, %{scheduled_faults: [%{fault: {:fault_script, [:drop_responses]}}]}} =
             Simulator.info()

    assert_eventually(fn ->
      assert {:ok,
              %{
                next_fault: {:next_exchange, :drop_responses},
                pending_faults: [:drop_responses],
                scheduled_faults: []
              }} = Simulator.info()
    end)
  end

  test "fault scripts can wait on milestones between queued and slave-local steps" do
    device = SimSlave.from_driver(EK1100, name: :coupler)

    assert {:ok, _pid} = Simulator.start_link(devices: [device])

    assert :ok =
             Simulator.inject_fault(
               Fault.script([
                 Fault.drop_responses(),
                 Fault.wait_for(Fault.healthy_exchanges(2)),
                 Fault.disconnect(:coupler)
               ])
             )

    assert {:ok,
            %{
              next_fault: {:next_exchange, :drop_responses},
              pending_faults: [:drop_responses],
              scheduled_faults: [
                %{
                  fault:
                    {:fault_script,
                     [{:wait_for_milestone, {:healthy_exchanges, 2}}, {:disconnect, :coupler}]},
                  waiting_on: {:queued_exchange_steps, 1},
                  remaining: 1
                }
              ]
            }} = Simulator.info()

    datagram = %Datagram{
      cmd: 1,
      idx: 1,
      address: <<0::little-signed-16, 0x0010::little-unsigned-16>>,
      data: <<0, 0>>
    }

    assert {:error, :no_response} = Simulator.process_datagrams([datagram])

    assert {:ok,
            %{
              pending_faults: [],
              scheduled_faults: [
                %{
                  fault: {:fault_script, [{:disconnect, :coupler}]},
                  waiting_on: {:healthy_exchanges, 2},
                  remaining: 2
                }
              ]
            }} = Simulator.info()
  end

  test "info/0 reports milestone-scheduled faults and arms them after healthy exchanges" do
    device = SimSlave.from_driver(EK1100, name: :coupler)

    assert {:ok, _pid} = Simulator.start_link(devices: [device])

    assert :ok =
             Simulator.inject_fault(
               Fault.drop_responses()
               |> Fault.next()
               |> Fault.after_milestone(Fault.healthy_exchanges(2))
             )

    assert {:ok,
            %{
              scheduled_faults: [
                %{
                  fault: {:next_exchange, :drop_responses},
                  waiting_on: {:healthy_exchanges, 2},
                  remaining: 2
                }
              ]
            }} = Simulator.info()

    datagram = %Datagram{
      cmd: 1,
      idx: 1,
      address: <<0::little-signed-16, 0x0010::little-unsigned-16>>,
      data: <<0, 0>>
    }

    assert {:ok, [%Datagram{wkc: 1}]} = Simulator.process_datagrams([datagram])

    assert {:ok,
            %{
              scheduled_faults: [
                %{
                  fault: {:next_exchange, :drop_responses},
                  waiting_on: {:healthy_exchanges, 2},
                  remaining: 1
                }
              ]
            }} = Simulator.info()

    assert {:ok, [%Datagram{wkc: 1}]} = Simulator.process_datagrams([datagram])

    assert {:ok,
            %{next_fault: {:next_exchange, :drop_responses}, pending_faults: [:drop_responses]}} =
             Simulator.info()

    assert {:ok, %{scheduled_faults: []}} = Simulator.info()
  end

  test "nested milestone and timer scheduling is preserved until the final fault fires" do
    device = SimSlave.from_driver(EK1100, name: :coupler)

    assert {:ok, _pid} = Simulator.start_link(devices: [device])

    nested_fault =
      Fault.retreat_to_safeop(:coupler)
      |> Fault.after_ms(20)
      |> Fault.after_milestone(Fault.healthy_exchanges(2))

    assert :ok = Simulator.inject_fault(nested_fault)

    assert {:ok,
            %{
              scheduled_faults: [
                %{
                  fault: {:after_ms, 20, {:retreat_to_safeop, :coupler}},
                  waiting_on: {:healthy_exchanges, 2},
                  remaining: 2
                }
              ]
            }} = Simulator.info()

    datagram = %Datagram{
      cmd: 1,
      idx: 1,
      address: <<0::little-signed-16, 0x0010::little-unsigned-16>>,
      data: <<0, 0>>
    }

    assert {:ok, [%Datagram{wkc: 1}]} = Simulator.process_datagrams([datagram])

    assert {:ok,
            %{
              scheduled_faults: [
                %{
                  fault: {:after_ms, 20, {:retreat_to_safeop, :coupler}},
                  waiting_on: {:healthy_exchanges, 2},
                  remaining: 1
                }
              ]
            }} = Simulator.info()

    assert {:ok, [%Datagram{wkc: 1}]} = Simulator.process_datagrams([datagram])

    assert {:ok, %{scheduled_faults: [%{fault: {:retreat_to_safeop, :coupler}}]}} =
             Simulator.info()

    assert_eventually(fn ->
      assert {:ok, %{scheduled_faults: []}} = Simulator.info()
      assert {:ok, %{state: :safeop}} = Simulator.device_snapshot(:coupler)
    end)
  end

  @tag :raw_socket
  test "raw simulator endpoint processes EtherCAT frames over loopback" do
    device = SimSlave.from_driver(EK1100, name: :coupler)

    assert {:ok, supervisor} =
             Supervisor.start_link(
               [{Simulator, devices: [device], raw: [interface: @raw_loopback_interface]}],
               strategy: :one_for_one
             )

    %{socket: socket, ifindex: ifindex} = open_test_raw_socket!(@raw_loopback_interface)

    on_exit(fn ->
      :socket.close(socket)
      _ = stop_supervisor(supervisor)
    end)

    datagram = %Datagram{
      cmd: 1,
      idx: 7,
      address: <<0::little-signed-16, 0x0010::little-unsigned-16>>,
      data: <<0, 0>>
    }

    assert {:ok, payload} = Frame.encode([datagram])
    raw_frame = build_test_raw_frame(payload)

    assert :ok = :socket.sendto(socket, raw_frame, sockaddr_ll(ifindex, @broadcast_mac))

    assert {:ok, [%Datagram{cmd: 1, idx: 7, wkc: 1, data: <<0, 0>>}]} =
             recv_processed_reply(socket, 1_000)
  end

  defp open_test_raw_socket!(interface) do
    with {:ok, ifindex} <- :net.if_name2index(String.to_charlist(interface)),
         {:ok, socket} <- :socket.open(@af_packet, :raw, {:raw, @ethertype}),
         :ok <- :socket.bind(socket, sockaddr_ll(ifindex)) do
      %{socket: socket, ifindex: ifindex}
    else
      {:error, reason} ->
        flunk("raw simulator tests require AF_PACKET access on #{interface}: #{inspect(reason)}")
    end
  end

  defp recv_processed_reply(socket, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    recv_processed_reply_until(socket, deadline_ms)
  end

  defp recv_processed_reply_until(socket, deadline_ms) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      flunk("timed out waiting for processed raw simulator reply")
    else
      case :socket.recvmsg(socket, 0, 0, remaining_ms) do
        {:ok, msg} ->
          case decode_test_frame(msg_data(msg)) do
            {:ok, datagrams} when datagrams != [] ->
              if Enum.any?(datagrams, &(&1.wkc != 0 or &1.circular)) do
                {:ok, datagrams}
              else
                recv_processed_reply_until(socket, deadline_ms)
              end

            _ ->
              recv_processed_reply_until(socket, deadline_ms)
          end

        {:error, reason} ->
          flunk("failed to receive raw simulator reply: #{inspect(reason)}")
      end
    end
  end

  defp decode_test_frame(
         <<_destination::binary-size(6), _source::binary-size(6), @ethertype::big-unsigned-16,
           payload_with_padding::binary>>
       ) do
    with {:ok, payload, _padding} <- split_payload_and_padding(payload_with_padding) do
      Frame.decode(payload)
    end
  end

  defp decode_test_frame(_frame), do: {:error, :not_ethercat}

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

  defp build_test_raw_frame(payload) do
    frame_body =
      <<@broadcast_mac::binary, @test_source_mac::binary, @ethertype::big-unsigned-16,
        payload::binary>>

    pad_needed = max(0, @min_frame_size - byte_size(frame_body))
    <<frame_body::binary, 0::size(pad_needed)-unit(8)>>
  end

  defp sockaddr_ll(ifindex, mac \\ <<0::48>>) do
    mac_padded =
      if byte_size(mac) < 8, do: <<mac::binary, 0::size((8 - byte_size(mac)) * 8)>>, else: mac

    addr =
      <<@ethertype::16-big, ifindex::32-native, 0::16, 0::8, 6::8, mac_padded::binary-size(8)>>

    %{family: @af_packet, addr: addr}
  end

  defp msg_data(%{iov: [data | _]}), do: data
  defp msg_data(_), do: <<>>

  defp stop_supervisor(supervisor) when is_pid(supervisor) do
    if Process.alive?(supervisor) do
      Supervisor.stop(supervisor)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
