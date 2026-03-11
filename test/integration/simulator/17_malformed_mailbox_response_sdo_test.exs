defmodule EtherCAT.Integration.Simulator.MalformedMailboxResponseSDOTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.Drivers.{EK1100, MailboxDevice}
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
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

  test "wrong mailbox types surface as exact CoE errors" do
    value = "hello-sim\0\0\0"

    assert :preop_ready = EtherCAT.state()

    assert :ok =
             Simulator.inject_fault(
               {:mailbox_protocol_fault, :mailbox, 0x2001, 0x01, :upload_init,
                {:mailbox_type, 0x04}}
             )

    assert {:error, {:unexpected_mailbox_type, 4}} =
             EtherCAT.upload_sdo(:mailbox, 0x2001, 0x01)

    assert :preop_ready = EtherCAT.state()

    assert :ok = Simulator.clear_faults()

    assert {:ok, ^value} = EtherCAT.upload_sdo(:mailbox, 0x2001, 0x01)
    assert :preop_ready = EtherCAT.state()
  end

  test "wrong CoE services surface as exact parser errors" do
    value = "hello-sim\0\0\0"

    assert :preop_ready = EtherCAT.state()

    assert :ok =
             Simulator.inject_fault(
               {:mailbox_protocol_fault, :mailbox, 0x2001, 0x01, :upload_init,
                {:coe_service, 0x02}}
             )

    assert {:error, {:unexpected_coe_service, 2}} =
             EtherCAT.upload_sdo(:mailbox, 0x2001, 0x01)

    assert :preop_ready = EtherCAT.state()

    assert :ok = Simulator.clear_faults()

    assert {:ok, ^value} = EtherCAT.upload_sdo(:mailbox, 0x2001, 0x01)
    assert :preop_ready = EtherCAT.state()
  end
end
