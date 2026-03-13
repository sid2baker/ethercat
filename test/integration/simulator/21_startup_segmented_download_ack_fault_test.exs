defmodule EtherCAT.Integration.Simulator.StartupSegmentedDownloadAckFaultTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.Drivers.{EK1100, SegmentedConfiguredMailboxDevice}
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @failure {:mailbox_config_failed, 0x2003, 0x01, :invalid_coe_response}

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    :ok
  end

  test "startup segmented download ack faults surface as activation-blocked preop configuration failures" do
    expected = startup_blob()

    devices = [
      Slave.from_driver(EK1100, name: :coupler),
      Slave.from_driver(SegmentedConfiguredMailboxDevice, name: :mailbox)
    ]

    slaves = [
      %SlaveConfig{
        name: :coupler,
        driver: EK1100,
        process_data: :none,
        target_state: :op
      },
      %SlaveConfig{
        name: :mailbox,
        driver: SegmentedConfiguredMailboxDevice,
        process_data: :none,
        target_state: :op
      }
    ]

    simulator = SimulatorRing.start_simulator!(devices: devices, connections: [])

    assert :ok =
             Simulator.inject_fault(
               Fault.mailbox_protocol_fault(
                 :mailbox,
                 0x2003,
                 0x01,
                 :download_segment,
                 :invalid_coe_payload
               )
               |> Fault.after_milestone(Fault.mailbox_step(:mailbox, :download_segment, 1))
             )

    SimulatorRing.start_master!(simulator.port,
      start_opts: [domains: [], slaves: slaves, frame_timeout_ms: 20]
    )

    assert {:error,
            {:activation_failed, %{mailbox: {:safeop, {:preop_configuration_failed, @failure}}}}} =
             EtherCAT.await_running(2_500)

    assert {:ok, :activation_blocked} = EtherCAT.state()

    assert {:ok, %{al_state: :preop, configuration_error: @failure}} =
             EtherCAT.slave_info(:mailbox)

    assert :ok = Simulator.clear_faults()
    assert :ok = EtherCAT.stop()

    SimulatorRing.start_master!(simulator.port,
      start_opts: [domains: [], slaves: slaves, frame_timeout_ms: 20]
    )

    assert :ok = EtherCAT.await_operational(2_500)
    assert {:ok, :operational} = EtherCAT.state()
    assert {:ok, %{configuration_error: nil}} = EtherCAT.slave_info(:mailbox)
    assert {:ok, ^expected} = EtherCAT.upload_sdo(:mailbox, 0x2003, 0x01)
  end

  defp startup_blob do
    0..191
    |> Enum.map(fn value -> rem(value * 13 + 7, 256) end)
    |> :erlang.list_to_binary()
  end
end
