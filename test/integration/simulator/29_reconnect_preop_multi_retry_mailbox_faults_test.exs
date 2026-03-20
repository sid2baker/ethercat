defmodule EtherCAT.Integration.Simulator.ReconnectPreopMultiRetryMailboxFaultsTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Scenario
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

  @disconnect_steps 30
  @second_failure {:mailbox_config_failed, 0x2003, 0x01, :invalid_coe_response}

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    SimulatorRing.boot_operational!(ring: :segmented)
    :ok
  end

  test "successive reconnect PREOP retries can retain different mailbox failures before eventual recovery" do
    expected = SimulatorRing.startup_blob(:segmented)

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
          ),
          Fault.wait_for(Fault.mailbox_step(:mailbox, :download_init, 1)),
          Fault.mailbox_protocol_fault(
            :mailbox,
            0x2003,
            0x01,
            :download_segment,
            :invalid_coe_payload
          )
        ]

    Scenario.new()
    |> Scenario.trace()
    |> Scenario.inject_fault(Fault.script(fault_script))
    |> Scenario.act(
      "first reconnect retry retains the timeout while the second scripted fault is still waiting",
      fn _ctx ->
        Expect.eventually(
          fn ->
            Expect.master_state(:operational)
            Expect.domain(:main, cycle_health: :healthy)

            assert {:ok,
                    %{
                      scheduled_faults: [
                        %{
                          fault:
                            {:fault_script,
                             [
                               {:mailbox_protocol_fault, :mailbox, 0x2003, 0x01,
                                :download_segment, :invalid_coe_payload}
                             ]},
                          waiting_on: {:mailbox_step, :mailbox, :download_init, 1},
                          remaining: 1
                        }
                      ]
                    }} = Simulator.info()
          end,
          attempts: 220,
          label:
            "first reconnect retry retains the timeout while the second scripted fault is still waiting"
        )
      end
    )
    |> Scenario.act("write output ch1 high", fn _ctx ->
      assert :ok = EtherCAT.Raw.write_output(:outputs, :ch1, 1)
    end)
    |> Scenario.act("pdo flow still works while mailbox retries remain degraded", fn _ctx ->
      Expect.eventually(
        fn ->
          assert {:ok, {true, updated_at_us}} = EtherCAT.Raw.read_input(:inputs, :ch1)
          assert is_integer(updated_at_us)
          Expect.signal(:outputs, :ch1, value: true)
        end,
        label: "pdo flow still works while mailbox retries remain degraded"
      )
    end)
    |> Scenario.act(
      "later retry retains the second distinct mailbox failure and drains the script",
      fn _ctx ->
        Expect.eventually(
          fn ->
            Expect.master_state(:operational)
            Expect.domain(:main, cycle_health: :healthy)

            Expect.slave(:mailbox, configuration_error: @second_failure)
            assert {:ok, %{pending_faults: [], scheduled_faults: []}} = Simulator.info()
          end,
          attempts: 360,
          label: "later retry retains the second distinct mailbox failure and drains the script"
        )
      end
    )
    |> Scenario.act(
      "later retry self-heals after both scripted mailbox faults have fired",
      fn _ctx ->
        Expect.eventually(
          fn ->
            Expect.master_state(:operational)
            Expect.slave_fault(:mailbox, nil)
            Expect.slave(:mailbox, al_state: :op, configuration_error: nil)
            Expect.domain(:main, cycle_health: :healthy)

            assert {:ok, ^expected} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)
            Expect.simulator_queue_empty()
          end,
          attempts: 420,
          label: "later retry self-heals after both scripted mailbox faults have fired"
        )
      end
    )
    |> Scenario.act("trace captured both retained failures and later clear", fn %{trace: trace} ->
      Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
        metadata: [
          slave: :mailbox,
          to: :preop,
          to_detail: :preop_configuration_failed
        ]
      )

      Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
        metadata: [
          slave: :mailbox,
          to: :preop,
          to_detail: :preop_configuration_failed
        ]
      )

      Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
        metadata: [
          slave: :mailbox,
          from: :preop,
          from_detail: :preop_configuration_failed,
          to: nil
        ]
      )
    end)
    |> Scenario.run()
  end
end
