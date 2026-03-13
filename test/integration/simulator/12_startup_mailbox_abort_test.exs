defmodule EtherCAT.Integration.Simulator.StartupMailboxAbortTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.Drivers.{ConfiguredMailboxDevice, EK1100}
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @abort_code 0x0601_0002
  @failure {:mailbox_config_failed, 0x2000, 0x02, {:sdo_abort, 0x2000, 0x02, @abort_code}}

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    :ok
  end

  test "startup mailbox aborts surface as activation-blocked preop configuration failures" do
    devices = [
      Slave.from_driver(EK1100, name: :coupler),
      Slave.from_driver(ConfiguredMailboxDevice, name: :mailbox)
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
        driver: ConfiguredMailboxDevice,
        process_data: :none,
        target_state: :op
      }
    ]

    simulator = SimulatorRing.start_simulator!(devices: devices, connections: [])

    assert :ok = Simulator.inject_fault(Fault.mailbox_abort(:mailbox, 0x2000, 0x02, @abort_code))

    SimulatorRing.start_master!(simulator,
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

    SimulatorRing.start_master!(simulator,
      start_opts: [domains: [], slaves: slaves, frame_timeout_ms: 20]
    )

    assert :ok = EtherCAT.await_operational(2_500)
    assert {:ok, :operational} = EtherCAT.state()
    assert {:ok, %{configuration_error: nil}} = EtherCAT.slave_info(:mailbox)
    assert {:ok, <<1>>} = EtherCAT.upload_sdo(:mailbox, 0x2000, 0x02)
  end
end
