defmodule EtherCAT.Integration.Simulator.StartupPreopHealthPollIsolationTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Driver.{EK1100, EL2809}
  alias EtherCAT.Integration.Expect
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @wait_attempts 20

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    devices = [
      Slave.from_driver(EK1100, name: :coupler),
      Slave.from_driver(EL2809, name: :outputs)
    ]

    slaves = [
      %SlaveConfig{
        name: :coupler,
        driver: EK1100,
        process_data: :none,
        target_state: :preop
      },
      %SlaveConfig{
        name: :outputs,
        driver: EL2809,
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

  test "startup-held preop slaves do not background poll into recovery" do
    assert {:ok, :preop_ready} = EtherCAT.state()
    assert :ok = Simulator.inject_fault(Fault.disconnect(:outputs))

    Expect.stays(
      fn ->
        Expect.master_state(:preop_ready)
        Expect.slave_fault(:outputs, nil)
        Expect.slave(:outputs, al_state: :preop)
      end,
      attempts: @wait_attempts
    )
  end
end
