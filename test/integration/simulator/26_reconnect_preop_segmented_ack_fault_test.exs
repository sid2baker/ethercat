defmodule EtherCAT.Integration.Simulator.ReconnectPreopSegmentedAckFaultTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Scenario
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator.Fault

  @disconnect_steps 30
  @failure {:mailbox_config_failed, 0x2003, 0x01, :invalid_coe_response}

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    SimulatorRing.boot_operational!(ring: :segmented)
    :ok
  end

  test "reconnect-time malformed segmented acknowledgements rerun PREOP configuration and self-heal after faults clear" do
    expected = SimulatorRing.startup_blob(:segmented)

    Scenario.new()
    |> Scenario.trace()
    |> Scenario.inject_fault(
      Fault.script(List.duplicate(Fault.disconnect(:mailbox), @disconnect_steps))
    )
    |> Scenario.inject_fault(
      Fault.mailbox_protocol_fault(
        :mailbox,
        0x2003,
        0x01,
        :download_segment,
        :invalid_coe_payload
      )
      |> Fault.after_milestone(Fault.mailbox_step(:mailbox, :download_segment, 1))
    )
    |> Scenario.act("mailbox holds malformed segmented ack failure in PREOP", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:operational)
          Expect.slave_fault(:mailbox, {:preop, {:preop_configuration_failed, @failure}})
          Expect.slave(:mailbox, al_state: :preop, configuration_error: @failure)
          Expect.domain(:main, cycle_health: :healthy)
        end,
        attempts: 220,
        label: "mailbox holds malformed segmented ack failure in PREOP"
      )
    end)
    |> Scenario.act("write output ch1 high", fn _ctx ->
      assert :ok = EtherCAT.Raw.write_output(:outputs, :ch1, 1)
    end)
    |> Scenario.act("pdo flow still works during malformed ack fault", fn _ctx ->
      Expect.eventually(
        fn ->
          assert {:ok, {true, updated_at_us}} = EtherCAT.Raw.read_input(:inputs, :ch1)
          assert is_integer(updated_at_us)
          Expect.signal(:outputs, :ch1, value: true)
        end,
        label: "pdo flow still works during malformed ack fault"
      )
    end)
    |> Scenario.clear_faults()
    |> Scenario.act("mailbox self-heals after malformed ack fault clear", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:operational)
          Expect.slave_fault(:mailbox, nil)
          Expect.slave(:mailbox, al_state: :op, configuration_error: nil)
          assert {:ok, ^expected} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)
          Expect.simulator_queue_empty()
        end,
        attempts: 220,
        label: "mailbox self-heals after malformed ack fault clear"
      )
    end)
    |> Scenario.run()
  end
end
