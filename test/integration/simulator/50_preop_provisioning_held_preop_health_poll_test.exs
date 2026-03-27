defmodule EtherCAT.Integration.Simulator.PreopProvisioningHeldPreopHealthPollTest do
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
      Hardware.coupler(target_state: :preop),
      Hardware.inputs(target_state: :preop),
      Hardware.outputs(target_state: :preop),
      %SlaveConfig{
        name: :mailbox,
        driver: SegmentedConfiguredMailboxDevice,
        process_data: :none,
        target_state: :preop,
        health_poll_ms: @mailbox_health_poll_ms
      }
    ]

    SimulatorRing.boot_preop_ready!(
      ring: :segmented,
      start_opts: [slaves: slaves],
      await_running_ms: 2_500
    )

    :ok
  end

  test "provisioning activation restores health polling for slaves intentionally left in preop" do
    expected = SimulatorRing.startup_blob(:segmented)

    Scenario.new()
    |> Scenario.trace()
    |> Scenario.act("baseline session is preop-ready without mailbox faults", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:preop_ready)
          Expect.slave_fault(:mailbox, nil)
          Expect.slave(:mailbox, al_state: :preop)
          assert {:ok, ^expected} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)
        end,
        attempts: 120,
        label: "preop-first session reaches preop_ready"
      )
    end)
    |> Scenario.act("configure only the PDO slaves for op and activate the ring", fn _ctx ->
      assert :ok = EtherCAT.Provisioning.configure_slave(:coupler, target_state: :op)
      assert :ok = EtherCAT.Provisioning.configure_slave(:inputs, target_state: :op)
      assert :ok = EtherCAT.Provisioning.configure_slave(:outputs, target_state: :op)
      assert :ok = EtherCAT.Provisioning.activate()
      assert :ok = EtherCAT.await_operational(2_500)
    end)
    |> Scenario.act(
      "ring is operational while mailbox remains intentionally held in preop",
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
          label: "mixed provisioning activation reaches operational with mailbox held in preop"
        )
      end
    )
    |> Scenario.inject_fault(Fault.disconnect(:mailbox) |> Fault.next(@disconnect_steps))
    |> Scenario.act(
      "mailbox disconnect becomes a visible slave-local fault while runtime stays healthy",
      fn _ctx ->
        Expect.eventually(
          fn ->
            Expect.master_state(:operational)
            Expect.domain(:main, cycle_health: :healthy)
            Expect.slave_fault(:mailbox, {:down, :no_response})
          end,
          attempts: 120,
          label: "mailbox disconnect is visible after mixed provisioning activation"
        )
      end
    )
    |> Scenario.act("mailbox reconnect heals back to preop", fn _ctx ->
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
        label: "mailbox reconnect returns to preop after mixed provisioning activation"
      )
    end)
    |> Scenario.run()
  end
end
