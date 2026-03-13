defmodule EtherCAT.Integration.Simulator.ReconnectPreopDisconnectSafeopChainTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Scenario
  alias EtherCAT.IntegrationSupport.SegmentedMailboxRing
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator.Fault

  @disconnect_steps 30
  @mailbox_failure {:mailbox_config_failed, 0x2003, 0x01, :response_timeout}
  @event_triggered_disconnect Fault.disconnect(:outputs) |> Fault.next(@disconnect_steps)
  @recovery_followup_safeop Fault.retreat_to_safeop(:inputs)

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    # The follow-up SAFEOP retreat lands on :inputs, so enable health polling there too.
    SegmentedMailboxRing.boot_operational!(slave_config_opts: [input_health_poll_ms: 20])

    :ok
  end

  test "mailbox reconnect failure can arm a disconnect whose recovery arms SAFEOP" do
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
    |> Scenario.inject_fault_on_event(
      [:ethercat, :master, :state, :changed],
      @recovery_followup_safeop,
      metadata: [to: :recovering]
    )
    |> Scenario.inject_fault(Fault.script(mailbox_fault_script))
    |> Scenario.expect_eventually(
      "mailbox fault retention arms the later disconnect and recovery follow-up",
      fn %{trace: trace} ->
        Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
          metadata: [
            slave: :mailbox,
            to: {:preop, {:preop_configuration_failed, @mailbox_failure}}
          ]
        )

        Expect.trace_event(trace, [:ethercat, :master, :state, :changed],
          metadata: [to: :recovering]
        )

        Expect.trace_note(trace, "telemetry trigger matched",
          metadata: [fault: "next 30 exchanges disconnect outputs"]
        )

        Expect.trace_note(trace, "telemetry-triggered fault injected",
          metadata: [fault: "next 30 exchanges disconnect outputs"]
        )

        Expect.trace_note(trace, "telemetry trigger matched",
          metadata: [fault: "retreat inputs to SAFEOP"]
        )

        Expect.trace_note(trace, "telemetry-triggered fault injected",
          metadata: [fault: "retreat inputs to SAFEOP"]
        )
      end,
      attempts: 260
    )
    |> Scenario.expect_eventually(
      "trace captures the later disconnect after the retained mailbox fault arms it",
      fn %{trace: trace} ->
        Expect.trace_sequence(trace, [
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [
             slave: :mailbox,
             to: {:preop, {:preop_configuration_failed, @mailbox_failure}}
           ]},
          {:note, "telemetry trigger matched",
           metadata: [fault: "next 30 exchanges disconnect outputs"]},
          {:note, "telemetry-triggered fault injected",
           metadata: [fault: "next 30 exchanges disconnect outputs"]},
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [slave: :outputs, to: {:down, :disconnected}]}
        ])
      end,
      attempts: 160
    )
    |> Scenario.expect_eventually(
      "the recovery-triggered SAFEOP retreat becomes visible on the inputs slave",
      fn _ctx ->
        Expect.slave_fault(:inputs, {:retreated, :safeop})
        Expect.slave(:inputs, al_state: :safeop)
      end,
      attempts: 160
    )
    |> Scenario.expect_eventually(
      "outputs heal first while the mailbox and SAFEOP faults remain visible",
      fn _ctx ->
        Expect.master_state(:operational)
        Expect.domain(:main, cycle_health: :healthy)
        Expect.slave_fault(:outputs, nil)
        Expect.slave(:outputs, al_state: :op)
        Expect.slave_fault(:mailbox, {:preop, {:preop_configuration_failed, @mailbox_failure}})
        Expect.slave(:mailbox, al_state: :preop, configuration_error: @mailbox_failure)
        Expect.slave_fault(:inputs, {:retreated, :safeop})
        Expect.slave(:inputs, al_state: :safeop)
      end,
      attempts: 280
    )
    |> Scenario.expect_eventually(
      "the inputs and mailbox retry paths later heal too",
      fn _ctx ->
        Expect.master_state(:operational)
        Expect.domain(:main, cycle_health: :healthy)
        Expect.slave_fault(:mailbox, nil)
        Expect.slave_fault(:outputs, nil)
        Expect.slave_fault(:inputs, nil)
        Expect.slave(:mailbox, al_state: :op, configuration_error: nil)
        Expect.slave(:outputs, al_state: :op)
        Expect.slave(:inputs, al_state: :op)
        assert {:ok, ^expected} = EtherCAT.upload_sdo(:mailbox, 0x2003, 0x01)
        Expect.simulator_queue_empty()
      end,
      attempts: 420
    )
    |> Scenario.act(
      "trace captured both telemetry trigger chains and all slave fault lifecycles",
      fn %{trace: trace} ->
        Expect.trace_sequence(trace, [
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [
             slave: :mailbox,
             to: {:preop, {:preop_configuration_failed, @mailbox_failure}}
           ]},
          {:note, "telemetry trigger matched",
           metadata: [fault: "next 30 exchanges disconnect outputs"]},
          {:note, "telemetry-triggered fault injected",
           metadata: [fault: "next 30 exchanges disconnect outputs"]},
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [slave: :outputs, to: {:down, :disconnected}]}
        ])

        Expect.trace_sequence(trace, [
          {:event, [:ethercat, :master, :state, :changed], metadata: [to: :recovering]},
          {:note, "telemetry trigger matched", metadata: [fault: "retreat inputs to SAFEOP"]},
          {:note, "telemetry-triggered fault injected",
           metadata: [fault: "retreat inputs to SAFEOP"]},
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [slave: :inputs, to: {:retreated, :safeop}]}
        ])

        Expect.trace_sequence(trace, [
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [slave: :outputs, to: {:down, :disconnected}]},
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [
             slave: :outputs,
             from: {:down, :disconnected},
             to: {:reconnecting, :authorized}
           ]},
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [slave: :outputs, from: {:reconnecting, :authorized}, to: nil]}
        ])

        Expect.trace_sequence(trace, [
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [slave: :inputs, to: {:retreated, :safeop}]},
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [slave: :inputs, from: {:retreated, :safeop}, to: nil]}
        ])

        Expect.trace_sequence(trace, [
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [
             slave: :mailbox,
             to: {:preop, {:preop_configuration_failed, @mailbox_failure}}
           ]},
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [
             slave: :mailbox,
             from: {:preop, {:preop_configuration_failed, @mailbox_failure}},
             to: nil
           ]}
        ])

        Expect.trace_event(trace, [:ethercat, :master, :state, :changed],
          metadata: [to: :operational]
        )
      end
    )
    |> Scenario.run()
  end
end
