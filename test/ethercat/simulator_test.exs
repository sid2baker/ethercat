defmodule EtherCAT.SimulatorTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Bus.Datagram
  alias EtherCAT.IntegrationSupport.Drivers.EK1100
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.Slave, as: SimSlave
  alias EtherCAT.Simulator.Udp.Fault, as: UdpFault

  @loopback {127, 0, 0, 1}

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

    assert UdpFault.describe(UdpFault.truncate() |> UdpFault.next(2)) ==
             "next 2 UDP replies truncate"
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

    Process.sleep(80)

    assert {:ok,
            %{next_fault: {:next_exchange, :drop_responses}, pending_faults: [:drop_responses]}} =
             Simulator.info()

    assert {:ok, %{scheduled_faults: []}} = Simulator.info()
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
end
