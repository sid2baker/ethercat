defmodule EtherCAT.Integration.Simulator.ReconnectPreopMailboxTimeoutTest do
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

  test "reconnect-time mailbox response timeouts rerun PREOP configuration and self-heal after faults clear" do
    expected = SegmentedMailboxRing.startup_blob()

    Scenario.new()
    |> Scenario.trace()
    |> Scenario.inject_fault(
      Fault.script(List.duplicate(Fault.disconnect(:mailbox), @disconnect_steps))
    )
    |> Scenario.inject_fault(
      Fault.mailbox_protocol_fault(:mailbox, 0x2003, 0x01, :download_segment, :drop_response)
      |> Fault.after_milestone(Fault.mailbox_step(:mailbox, :download_segment, 1))
    )
    |> Scenario.expect_eventually(
      "mailbox drops to PREOP with retained response timeout",
      fn _ctx ->
        Expect.master_state(:operational)
        Expect.slave_fault(:mailbox, {:preop, {:preop_configuration_failed, @failure}})
        Expect.slave(:mailbox, al_state: :preop, configuration_error: @failure)
        Expect.domain(:main, cycle_health: :healthy)
      end,
      attempts: 220
    )
    |> Scenario.act("write output ch1 high", fn _ctx ->
      assert :ok = EtherCAT.write_output(:outputs, :ch1, 1)
    end)
    |> Scenario.expect_eventually("pdo flow still works during PREOP retry window", fn _ctx ->
      assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
      assert is_integer(updated_at_us)
      Expect.signal(:outputs, :ch1, value: true)
    end)
    |> Scenario.clear_faults()
    |> Scenario.expect_eventually(
      "mailbox self-heals after timeout fault clear",
      fn _ctx ->
        Expect.master_state(:operational)
        Expect.slave_fault(:mailbox, nil)
        Expect.slave(:mailbox, al_state: :op, configuration_error: nil)
        assert {:ok, ^expected} = EtherCAT.upload_sdo(:mailbox, 0x2003, 0x01)
        Expect.simulator_queue_empty()
      end,
      attempts: 220
    )
    |> Scenario.run()
  end
end
