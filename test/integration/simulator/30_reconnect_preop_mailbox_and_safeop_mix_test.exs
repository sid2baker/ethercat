defmodule EtherCAT.Integration.Simulator.ReconnectPreopMailboxAndSafeopMixTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Scenario
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator.Fault

  @disconnect_steps 30
  @mailbox_failure {:mailbox_config_failed, 0x2003, 0x01, :response_timeout}

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    SimulatorRing.boot_operational!(ring: :segmented)
    :ok
  end

  test "mailbox reconnect degradation and a later SAFEOP retreat stay as separate slave-local faults" do
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
    |> Scenario.inject_fault_on_event(
      [:ethercat, :master, :slave_fault, :changed],
      Fault.retreat_to_safeop(:outputs),
      metadata: [slave: :mailbox, to: :preop, to_detail: :preop_configuration_failed]
    )
    |> Scenario.inject_fault(Fault.script(fault_script))
    |> Scenario.act("mailbox fault retention arms the telemetry-triggered SAFEOP retreat", fn %{
                                                                                                trace:
                                                                                                  trace
                                                                                              } ->
      Expect.eventually(
        fn ->
          Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
            metadata: [
              slave: :mailbox,
              to: :preop,
              to_detail: :preop_configuration_failed
            ]
          )

          Expect.trace_note(trace, "telemetry trigger matched",
            metadata: [fault: "retreat outputs to SAFEOP"]
          )

          Expect.trace_note(trace, "telemetry-triggered fault injected",
            metadata: [fault: "retreat outputs to SAFEOP"]
          )
        end,
        attempts: 220,
        label: "mailbox fault retention arms the telemetry-triggered SAFEOP retreat"
      )
    end)
    |> Scenario.act(
      "both slave-local faults coexist while the master remains operational",
      fn _ctx ->
        Expect.eventually(
          fn ->
            Expect.master_state(:operational)
            Expect.domain(:main, cycle_health: :healthy)

            Expect.slave_fault(
              :mailbox,
              {:preop, {:preop_configuration_failed, @mailbox_failure}}
            )

            Expect.slave_fault(:outputs, {:retreated, :safeop})
            Expect.slave(:mailbox, al_state: :preop, configuration_error: @mailbox_failure)
            Expect.slave(:outputs, al_state: :safeop)
          end,
          attempts: 120,
          label: "both slave-local faults coexist while the master remains operational"
        )
      end
    )
    |> Scenario.act("both slaves recover on their existing retry paths", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:operational)
          Expect.domain(:main, cycle_health: :healthy)
          Expect.slave_fault(:mailbox, nil)
          Expect.slave_fault(:outputs, nil)
          Expect.slave(:mailbox, al_state: :op, configuration_error: nil)
          Expect.slave(:outputs, al_state: :op)
          assert {:ok, ^expected} = EtherCAT.upload_sdo(:mailbox, 0x2003, 0x01)
          Expect.simulator_queue_empty()
        end,
        attempts: 360,
        label: "both slaves recover on their existing retry paths"
      )
    end)
    |> Scenario.act("trace captured both slave fault lifecycles independently", fn %{trace: trace} ->
      Expect.trace_note(trace, "telemetry trigger matched",
        metadata: [fault: "retreat outputs to SAFEOP"]
      )

      Expect.trace_note(trace, "telemetry-triggered fault injected",
        metadata: [fault: "retreat outputs to SAFEOP"]
      )

      Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
        metadata: [
          slave: :mailbox,
          to: :preop,
          to_detail: :preop_configuration_failed
        ]
      )

      Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
        metadata: [slave: :outputs, to: :retreated, to_detail: :safeop]
      )

      Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
        metadata: [slave: :outputs, from: :retreated, from_detail: :safeop, to: nil]
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
