defmodule EtherCAT.Integration.Simulator.MalformedSegmentResponseSDOTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Driver.EK1100
  alias EtherCAT.IntegrationSupport.Drivers.MailboxDevice
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    devices = [
      Slave.from_driver(EK1100, name: :coupler),
      Slave.from_driver(MailboxDevice, name: :mailbox)
    ]

    slaves = [
      %SlaveConfig{
        name: :coupler,
        driver: EK1100,
        process_data: :none,
        target_state: :preop
      },
      %SlaveConfig{
        name: :mailbox,
        driver: MailboxDevice,
        process_data: :none,
        target_state: :preop
      }
    ]

    SimulatorRing.boot_preop_ready!(
      simulator_opts: [devices: devices, connections: []],
      start_opts: [domains: [], slaves: slaves, frame_timeout_ms: 20],
      await_running_ms: 2_500
    )

    :ok
  end

  test "invalid segmented padding surfaces as an exact parser error" do
    blob = multi_segment_blob()

    assert {:ok, :preop_ready} = EtherCAT.state()

    assert :ok =
             Simulator.inject_fault(
               Fault.mailbox_protocol_fault(
                 :mailbox,
                 0x2003,
                 0x01,
                 :upload_segment,
                 :invalid_segment_padding
               )
             )

    assert {:error, {:invalid_segment_padding, 7}} =
             EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)

    assert {:ok, :preop_ready} = EtherCAT.state()

    assert :ok = Simulator.clear_faults()

    assert {:ok, ^blob} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)
    assert {:ok, :preop_ready} = EtherCAT.state()
  end

  test "unexpected segment commands surface as exact parser errors" do
    blob = multi_segment_blob()

    assert {:ok, :preop_ready} = EtherCAT.state()

    assert :ok =
             Simulator.inject_fault(
               Fault.mailbox_protocol_fault(
                 :mailbox,
                 0x2003,
                 0x01,
                 :upload_segment,
                 {:segment_command, 0x20}
               )
             )

    assert {:error, {:unexpected_sdo_segment_command, 0x20}} =
             EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)

    assert {:ok, :preop_ready} = EtherCAT.state()

    assert :ok = Simulator.clear_faults()

    assert {:ok, ^blob} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)
    assert {:ok, :preop_ready} = EtherCAT.state()
  end

  defp multi_segment_blob do
    0..191
    |> Enum.to_list()
    |> :erlang.list_to_binary()
  end
end
