defmodule EtherCAT.Integration.Simulator.OperationalHeldPreopSlaveReconnectTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Scenario
  alias EtherCAT.IntegrationSupport.Drivers.SegmentedConfiguredMailboxDevice
  alias EtherCAT.IntegrationSupport.{Hardware, SimulatorRing}
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @disconnect_steps 40
  @mailbox_health_poll_ms 20

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    slaves = [
      Hardware.coupler(),
      Hardware.inputs(),
      Hardware.outputs(),
      %SlaveConfig{
        name: :mailbox,
        driver: SegmentedConfiguredMailboxDevice,
        process_data: :none,
        target_state: :preop,
        health_poll_ms: @mailbox_health_poll_ms
      }
    ]

    SimulatorRing.boot_operational!(
      ring: :segmented,
      start_opts: [slaves: slaves],
      await_operational_ms: 2_500
    )

    :ok
  end

  test "held preop slaves stay runtime-visible and reconnect back to preop" do
    expected = SimulatorRing.startup_blob(:segmented)

    Scenario.new()
    |> Scenario.trace()
    |> Scenario.act(
      "baseline mixed-target ring is operational with mailbox held in preop",
      fn _ctx ->
        Expect.eventually(
          fn ->
            Expect.master_state(:operational)
            Expect.domain(:main, cycle_health: :healthy)
            Expect.slave_fault(:mailbox, nil)
            Expect.slave(:mailbox, al_state: :preop)
            assert {:ok, ^expected} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)
          end,
          attempts: 120,
          label: "mixed-target ring reaches operational with mailbox held in preop"
        )
      end
    )
    |> Scenario.inject_fault(Fault.disconnect(:mailbox) |> Fault.next(@disconnect_steps))
    |> Scenario.act(
      "disconnect becomes a slave-local fault while the master stays operational",
      fn _ctx ->
        Expect.eventually(
          fn ->
            Expect.master_state(:operational)
            Expect.domain(:main, cycle_health: :healthy)
            Expect.slave_fault(:mailbox, {:down, :no_response})
          end,
          attempts: 120,
          label: "disconnect becomes a visible slave-local fault"
        )
      end
    )
    |> Scenario.act("reconnect clears the fault and restores mailbox preop hold", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:operational)
          Expect.domain(:main, cycle_health: :healthy)
          Expect.slave_fault(:mailbox, nil)
          Expect.slave(:mailbox, al_state: :preop)
          assert {:ok, ^expected} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)
          Expect.simulator_queue_empty()
        end,
        attempts: 360,
        label: "mailbox reconnect restores held preop state"
      )
    end)
    |> Scenario.run()
  end
end
