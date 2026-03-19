defmodule EtherCAT.Integration.Simulator.ReconnectPreopDisconnectSafeopChainTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Scenario
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator.Fault

  @disconnect_steps 30
  @mailbox_failure {:mailbox_config_failed, 0x2003, 0x01, :response_timeout}
  @event_triggered_disconnect Fault.disconnect(:outputs) |> Fault.next(@disconnect_steps)
  @recovery_followup_safeop Fault.retreat_to_safeop(:inputs)

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    # The follow-up SAFEOP retreat lands on :inputs, so enable health polling there too.
    SimulatorRing.boot_operational!(
      ring: :segmented,
      slave_config_opts: [input_health_poll_ms: 20]
    )

    :ok
  end

  test "mailbox reconnect failure can arm a disconnect whose recovery arms SAFEOP" do
    expected = SimulatorRing.startup_blob(:segmented)

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
      metadata: [slave: :mailbox, to: :preop, to_detail: :preop_configuration_failed]
    )
    |> Scenario.inject_fault_on_event(
      [:ethercat, :master, :state, :changed],
      @recovery_followup_safeop,
      metadata: [to: :recovering]
    )
    |> Scenario.inject_fault(Fault.script(mailbox_fault_script))
    |> Scenario.act(
      "mailbox fault retention arms the later disconnect and recovery follow-up",
      fn %{trace: trace} ->
        Expect.eventually(
          fn ->
            Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
              metadata: [
                slave: :mailbox,
                to: :preop,
                to_detail: :preop_configuration_failed
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
          attempts: 260,
          label: "mailbox fault retention arms the later disconnect and recovery follow-up"
        )
      end
    )
    |> Scenario.act(
      "trace captures the later disconnect after the retained mailbox fault arms it",
      fn %{trace: trace} ->
        Expect.eventually(
          fn ->
            Expect.trace_sequence(trace, [
              {:event, [:ethercat, :master, :slave_fault, :changed],
               metadata: [
                 slave: :mailbox,
                 to: :preop,
                 to_detail: :preop_configuration_failed
               ]},
              {:note, "telemetry trigger matched",
               metadata: [fault: "next 30 exchanges disconnect outputs"]},
              {:note, "telemetry-triggered fault injected",
               metadata: [fault: "next 30 exchanges disconnect outputs"]},
              {:event, [:ethercat, :master, :slave_fault, :changed],
               metadata: [slave: :outputs, to: :down, to_detail: :no_response]}
            ])
          end,
          attempts: 160,
          label: "trace captures the later disconnect after the retained mailbox fault arms it"
        )
      end
    )
    |> Scenario.act(
      "the recovery-triggered SAFEOP retreat becomes visible on the inputs slave",
      fn _ctx ->
        Expect.eventually(
          fn ->
            Expect.slave_fault(:inputs, {:retreated, :safeop})
            Expect.slave(:inputs, al_state: :safeop)
          end,
          attempts: 160,
          label: "the recovery-triggered SAFEOP retreat becomes visible on the inputs slave"
        )
      end
    )
    |> Scenario.act(
      "outputs heal first while the mailbox and SAFEOP faults remain visible",
      fn _ctx ->
        Expect.eventually(
          fn ->
            Expect.master_state(:operational)
            Expect.domain(:main, cycle_health: :healthy)
            Expect.slave_fault(:outputs, nil)
            Expect.slave(:outputs, al_state: :op)

            Expect.slave_fault(
              :mailbox,
              {:preop, {:preop_configuration_failed, @mailbox_failure}}
            )

            Expect.slave(:mailbox, al_state: :preop, configuration_error: @mailbox_failure)
            Expect.slave_fault(:inputs, {:retreated, :safeop})
            Expect.slave(:inputs, al_state: :safeop)
          end,
          attempts: 280,
          label: "outputs heal first while the mailbox and SAFEOP faults remain visible"
        )
      end
    )
    |> Scenario.act("the inputs and mailbox retry paths later heal too", fn _ctx ->
      Expect.eventually(
        fn ->
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
        attempts: 420,
        label: "the inputs and mailbox retry paths later heal too"
      )
    end)
    |> Scenario.act(
      "trace captured both telemetry trigger chains and all slave fault lifecycles",
      fn %{trace: trace} ->
        Expect.trace_sequence(trace, [
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [
             slave: :mailbox,
             to: :preop,
             to_detail: :preop_configuration_failed
           ]},
          {:note, "telemetry trigger matched",
           metadata: [fault: "next 30 exchanges disconnect outputs"]},
          {:note, "telemetry-triggered fault injected",
           metadata: [fault: "next 30 exchanges disconnect outputs"]},
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [slave: :outputs, to: :down, to_detail: :no_response]}
        ])

        Expect.trace_sequence(trace, [
          {:event, [:ethercat, :master, :state, :changed], metadata: [to: :recovering]},
          {:note, "telemetry trigger matched", metadata: [fault: "retreat inputs to SAFEOP"]},
          {:note, "telemetry-triggered fault injected",
           metadata: [fault: "retreat inputs to SAFEOP"]},
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [slave: :inputs, to: :retreated, to_detail: :safeop]}
        ])

        Expect.trace_sequence(trace, [
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [slave: :outputs, to: :down, to_detail: :no_response]},
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [
             slave: :outputs,
             from: :down,
             from_detail: :no_response,
             to: nil
           ]}
        ])

        Expect.trace_sequence(trace, [
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [slave: :inputs, to: :retreated, to_detail: :safeop]},
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [slave: :inputs, from: :retreated, from_detail: :safeop, to: nil]}
        ])

        Expect.trace_sequence(trace, [
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [
             slave: :mailbox,
             to: :preop,
             to_detail: :preop_configuration_failed
           ]},
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [
             slave: :mailbox,
             from: :preop,
             from_detail: :preop_configuration_failed,
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
