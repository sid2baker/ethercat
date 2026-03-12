defmodule EtherCAT.Integration.Simulator.ReconnectPreopScriptedSelfHealTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Scenario
  alias EtherCAT.IntegrationSupport.SegmentedMailboxRing
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator.Fault

  @disconnect_steps 30
  @failure {:mailbox_config_failed, 0x2003, 0x01, :response_timeout}

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    SegmentedMailboxRing.boot_operational!()
    :ok
  end

  test "a reconnect PREOP fault script can fail once and self-heal on a later retry without manual clear" do
    expected = SegmentedMailboxRing.startup_blob()

    fault_script =
      List.duplicate(Fault.disconnect(:mailbox), @disconnect_steps) ++
        [
          Fault.wait_for(Fault.mailbox_step(:mailbox, :download_segment, 1)),
          Fault.mailbox_protocol_fault(
            :mailbox,
            0x2003,
            0x01,
            :download_segment,
            :drop_response
          )
        ]

    Scenario.new()
    |> Scenario.trace()
    |> Scenario.inject_fault(Fault.script(fault_script))
    |> Scenario.expect_eventually(
      "first reconnect PREOP rebuild fails with the scripted timeout",
      fn _ctx ->
        Expect.master_state(:operational)
        Expect.slave_fault(:mailbox, {:preop, {:preop_configuration_failed, @failure}})
        Expect.slave(:mailbox, al_state: :preop, configuration_error: @failure)
        Expect.domain(:main, cycle_health: :healthy)
        Expect.simulator_queue_empty()
      end,
      attempts: 220
    )
    |> Scenario.act("write output ch1 high", fn _ctx ->
      assert :ok = EtherCAT.write_output(:outputs, :ch1, 1)
    end)
    |> Scenario.expect_eventually(
      "pdo flow still works while the mailbox slave waits for retry",
      fn _ctx ->
        assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
        assert is_integer(updated_at_us)
        Expect.signal(:outputs, :ch1, value: true)
      end
    )
    |> Scenario.expect_eventually(
      "later retry self-heals without manual fault clearing",
      fn _ctx ->
        Expect.master_state(:operational)
        Expect.slave_fault(:mailbox, nil)
        Expect.slave(:mailbox, al_state: :op, configuration_error: nil)
        Expect.domain(:main, cycle_health: :healthy)
        assert {:ok, ^expected} = EtherCAT.upload_sdo(:mailbox, 0x2003, 0x01)
        Expect.simulator_queue_empty()
      end,
      attempts: 320
    )
    |> Scenario.run()
  end
end
