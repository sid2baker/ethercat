defmodule EtherCAT.Integration.Simulator.RecoveringEntryFollowupSafeopTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Scenario
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator.Fault

  @disconnect_steps 30

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    SimulatorRing.boot_operational!()
    :ok
  end

  test "a follow-up safeop retreat can be armed from master recovery entry" do
    Scenario.new()
    |> Scenario.trace()
    |> Scenario.inject_fault(Fault.disconnect(:outputs) |> Fault.next(@disconnect_steps))
    |> Scenario.inject_fault_on_event(
      [:ethercat, :master, :state, :changed],
      Fault.retreat_to_safeop(:inputs),
      metadata: [to: :recovering]
    )
    |> Scenario.expect_eventually(
      "the trace captures the recovery entry",
      fn %{trace: trace} ->
        Expect.trace_event(trace, [:ethercat, :master, :state, :changed],
          metadata: [to: :recovering]
        )
      end,
      attempts: 120
    )
    |> Scenario.expect_eventually(
      "the follow-up safeop retreat is triggered from telemetry",
      fn %{trace: trace} ->
        Expect.trace_note(trace, "telemetry-triggered fault injected",
          metadata: [fault: "retreat inputs to SAFEOP"]
        )
      end,
      attempts: 120
    )
    |> Scenario.expect_eventually(
      "both faults clear on their normal retry paths",
      fn _ctx ->
        Expect.master_state(:operational)
        Expect.domain(:main, cycle_health: :healthy)
        Expect.slave_fault(:outputs, nil)
        Expect.slave_fault(:inputs, nil)
        Expect.slave(:outputs, al_state: :op)
        Expect.slave(:inputs, al_state: :op)
        Expect.simulator_queue_empty()
      end,
      attempts: 240
    )
    |> Scenario.act("trace captured the recovery entry and telemetry-triggered follow-up", fn %{
                                                                                                trace:
                                                                                                  trace
                                                                                              } ->
      Expect.trace_event(trace, [:ethercat, :master, :state, :changed],
        metadata: [to: :recovering]
      )

      Expect.trace_note(trace, "telemetry trigger matched",
        metadata: [fault: "retreat inputs to SAFEOP"]
      )

      Expect.trace_note(trace, "telemetry-triggered fault injected",
        metadata: [fault: "retreat inputs to SAFEOP"]
      )

      Expect.trace_event(trace, [:ethercat, :master, :state, :changed],
        metadata: [to: :operational]
      )
    end)
    |> Scenario.run()
  end
end
