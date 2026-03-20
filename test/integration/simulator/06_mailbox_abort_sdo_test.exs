defmodule EtherCAT.Integration.Simulator.MailboxAbortSDOTest do
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

  test "public sdo upload returns a mailbox abort without degrading the master" do
    assert {:ok, :preop_ready} = EtherCAT.state()
    assert {:ok, <<0x34, 0x12>>} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2000, 0x01)

    assert :ok =
             Simulator.inject_fault(Fault.mailbox_abort(:mailbox, 0x2000, 0x01, 0x0601_0002))

    assert {:error, {:sdo_abort, 0x2000, 0x01, 0x0601_0002}} =
             EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2000, 0x01)

    assert {:ok, :preop_ready} = EtherCAT.state()

    assert :ok = Simulator.clear_faults()

    assert {:ok, <<0x34, 0x12>>} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2000, 0x01)
    assert {:ok, :preop_ready} = EtherCAT.state()
  end
end
