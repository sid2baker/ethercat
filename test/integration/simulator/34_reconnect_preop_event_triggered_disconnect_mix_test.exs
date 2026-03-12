defmodule EtherCAT.Integration.Simulator.ReconnectPreopEventTriggeredDisconnectMixTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Scenario
  alias EtherCAT.IntegrationSupport.SegmentedMailboxRing
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator.Fault

  @disconnect_steps 30
  @mailbox_failure {:mailbox_config_failed, 0x2003, 0x01, :response_timeout}
  @event_triggered_disconnect Fault.disconnect(:outputs) |> Fault.next(@disconnect_steps)

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    SegmentedMailboxRing.boot_operational!()
    :ok
  end

  test "retained mailbox PREOP fault can arm a later counted disconnect through telemetry" do
    expected = SegmentedMailboxRing.startup_blob()

    mailbox_fault_script =
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
    |> Scenario.inject_fault_on_event(
      [:ethercat, :master, :slave_fault, :changed],
      @event_triggered_disconnect,
      metadata: [slave: :mailbox, to: {:preop, {:preop_configuration_failed, @mailbox_failure}}]
    )
    |> Scenario.inject_fault(Fault.script(mailbox_fault_script))
    |> Scenario.expect_eventually(
      "mailbox reconnect PREOP rebuild retains the scripted timeout and arms the disconnect",
      fn %{trace: trace} ->
        Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
          metadata: [
            slave: :mailbox,
            to: {:preop, {:preop_configuration_failed, @mailbox_failure}}
          ]
        )

        Expect.trace_note(trace, "telemetry trigger matched",
          metadata: [fault: "next 30 exchanges disconnect outputs"]
        )

        Expect.trace_note(trace, "telemetry-triggered fault injected",
          metadata: [fault: "next 30 exchanges disconnect outputs"]
        )
      end,
      attempts: 220
    )
    |> Scenario.expect_eventually(
      "output disconnect drives recovery while the mailbox fault remains retained",
      fn _ctx ->
        Expect.master_state(:recovering)
        Expect.slave_fault(:mailbox, {:preop, {:preop_configuration_failed, @mailbox_failure}})
        Expect.slave_fault(:outputs, {:down, :disconnected})
      end,
      attempts: 120
    )
    |> Scenario.expect_eventually(
      "output reconnect heals first while the mailbox failure still remains",
      fn _ctx ->
        Expect.master_state(:operational)
        Expect.domain(:main, cycle_health: :healthy)
        Expect.slave_fault(:outputs, nil)
        Expect.slave(:outputs, al_state: :op)
        Expect.slave_fault(:mailbox, {:preop, {:preop_configuration_failed, @mailbox_failure}})
        Expect.slave(:mailbox, al_state: :preop, configuration_error: @mailbox_failure)
      end,
      attempts: 240
    )
    |> Scenario.expect_eventually(
      "the mailbox retry path later heals as well",
      fn _ctx ->
        Expect.master_state(:operational)
        Expect.domain(:main, cycle_health: :healthy)
        Expect.slave_fault(:mailbox, nil)
        Expect.slave_fault(:outputs, nil)
        Expect.slave(:mailbox, al_state: :op, configuration_error: nil)
        Expect.slave(:outputs, al_state: :op)
        assert {:ok, ^expected} = EtherCAT.upload_sdo(:mailbox, 0x2003, 0x01)
        Expect.simulator_queue_empty()
      end,
      attempts: 360
    )
    |> Scenario.act(
      "trace captured the event-triggered disconnect and retained mailbox fault",
      fn %{
           trace: trace
         } ->
        Expect.trace_note(trace, "telemetry trigger matched",
          metadata: [fault: "next 30 exchanges disconnect outputs"]
        )

        Expect.trace_note(trace, "telemetry-triggered fault injected",
          metadata: [fault: "next 30 exchanges disconnect outputs"]
        )

        Expect.trace_event(trace, [:ethercat, :master, :state, :changed],
          metadata: [to: :recovering]
        )

        Expect.trace_event(trace, [:ethercat, :master, :state, :changed],
          metadata: [to: :operational]
        )

        Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
          metadata: [
            slave: :mailbox,
            to: {:preop, {:preop_configuration_failed, @mailbox_failure}}
          ]
        )

        Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
          metadata: [slave: :outputs, to: {:down, :disconnected}]
        )

        Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
          metadata: [
            slave: :outputs,
            from: {:down, :disconnected},
            to: {:reconnecting, :authorized}
          ]
        )

        Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
          metadata: [slave: :outputs, from: {:reconnecting, :authorized}, to: nil]
        )

        Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
          metadata: [
            slave: :mailbox,
            from: {:preop, {:preop_configuration_failed, @mailbox_failure}},
            to: nil
          ]
        )
      end
    )
    |> Scenario.run()
  end
end
