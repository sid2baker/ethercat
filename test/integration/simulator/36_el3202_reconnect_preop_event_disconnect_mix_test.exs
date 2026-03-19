defmodule EtherCAT.Integration.Simulator.EL3202ReconnectPreopEventDisconnectMixTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Scenario
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.Slave, as: SimSlave

  @disconnect_steps 30
  @event_triggered_disconnect Fault.disconnect(:outputs) |> Fault.next(@disconnect_steps)
  @channel1_reading %{
    ohms: 119.375,
    overrange: false,
    underrange: false,
    error: false,
    invalid: false,
    toggle: 0
  }
  @channel2_reading %{
    ohms: 99.3125,
    overrange: false,
    underrange: false,
    error: false,
    invalid: false,
    toggle: 1
  }

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    SimulatorRing.boot_operational!(
      ring: :hardware,
      slave_config_opts: [output_health_poll_ms: 20, rtd_health_poll_ms: 20]
    )

    :ok
  end

  test "captured EL3202 reconnect PREOP timeout can retain the RTD slave while PDO recovery still completes" do
    Scenario.new()
    |> Scenario.trace()
    |> Scenario.act("seed EL3202 RTD samples", fn _ctx ->
      assert :ok = SimSlave.set_value(:rtd, :channel1, rtd_sample(@channel1_reading))
      assert :ok = SimSlave.set_value(:rtd, :channel2, rtd_sample(@channel2_reading))
    end)
    |> Scenario.act("baseline EL3202 startup SDOs and typed RTD decode are healthy", fn _ctx ->
      Expect.eventually(
        fn ->
          assert {:ok, <<8, 0>>} = EtherCAT.upload_sdo(:rtd, 0x8000, 0x19)
          assert {:ok, <<8, 0>>} = EtherCAT.upload_sdo(:rtd, 0x8010, 0x19)
          assert_rtd_reading(:channel1, @channel1_reading)
          assert_rtd_reading(:channel2, @channel2_reading)
        end,
        attempts: 120,
        label: "baseline EL3202 startup SDOs and typed RTD decode are healthy"
      )
    end)
    |> Scenario.inject_fault_on_event(
      [:ethercat, :master, :slave_fault, :changed],
      @event_triggered_disconnect,
      metadata: [slave: :rtd, to: :preop, to_detail: :preop_configuration_failed]
    )
    |> Scenario.inject_fault(
      Fault.script(List.duplicate(Fault.disconnect(:rtd), @disconnect_steps))
    )
    |> Scenario.inject_fault(
      Fault.script([
        Fault.wait_for(Fault.mailbox_step(:rtd, :download_init, 1)),
        Fault.mailbox_protocol_fault(:rtd, 0x8010, 0x19, :download_init, :drop_response)
      ])
    )
    |> Scenario.act(
      "EL3202 reconnect PREOP timeout retains the RTD fault and arms the output disconnect",
      fn %{trace: trace} ->
        Expect.eventually(
          fn ->
            Expect.trace_sequence(trace, [
              {:event, [:ethercat, :master, :slave_fault, :changed],
               metadata: [slave: :rtd, to: :preop, to_detail: :preop_configuration_failed]},
              {:note, "telemetry trigger matched",
               metadata: [fault: "next 30 exchanges disconnect outputs"]},
              {:note, "telemetry-triggered fault injected",
               metadata: [fault: "next 30 exchanges disconnect outputs"]},
              {:event, [:ethercat, :master, :slave_fault, :changed],
               metadata: [slave: :outputs, to: :down, to_detail: :no_response]}
            ])
          end,
          attempts: 260,
          label:
            "EL3202 reconnect PREOP timeout retains the RTD fault and arms the output disconnect"
        )
      end
    )
    |> Scenario.act(
      "outputs heal on their own retry path after the retained EL3202 fault has already been recorded",
      fn %{trace: trace} ->
        Expect.eventually(
          fn ->
            Expect.slave_fault(:outputs, nil)
            Expect.slave(:outputs, al_state: :op)

            Expect.trace_sequence(trace, [
              {:event, [:ethercat, :master, :slave_fault, :changed],
               metadata: [slave: :rtd, to: :preop, to_detail: :preop_configuration_failed]},
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
          end,
          attempts: 320,
          label:
            "outputs heal on their own retry path after the retained EL3202 fault has already been recorded"
        )
      end
    )
    |> Scenario.act("EL3202 retry path heals and the master can leave recovery", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:operational)
          Expect.domain(:main, cycle_health: :healthy)
          Expect.slave_fault(:rtd, nil)
          Expect.slave_fault(:outputs, nil)
          Expect.slave(:rtd, al_state: :op, configuration_error: nil)
          assert {:ok, <<8, 0>>} = EtherCAT.upload_sdo(:rtd, 0x8000, 0x19)
          assert {:ok, <<8, 0>>} = EtherCAT.upload_sdo(:rtd, 0x8010, 0x19)
          assert_rtd_reading(:channel1, @channel1_reading)
          assert_rtd_reading(:channel2, @channel2_reading)
        end,
        attempts: 420,
        label: "EL3202 retry path heals and the master can leave recovery"
      )
    end)
    |> Scenario.act("write output ch1 high after the EL3202 heals", fn _ctx ->
      assert :ok = EtherCAT.write_output(:outputs, :ch1, 1)
    end)
    |> Scenario.act(
      "full-ring PDO flow and typed RTD decode both recover after the EL3202 heals",
      fn _ctx ->
        Expect.eventually(
          fn ->
            assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
            assert is_integer(updated_at_us)
            Expect.signal(:outputs, :ch1, value: true)
            assert_rtd_reading(:channel1, @channel1_reading)
            assert_rtd_reading(:channel2, @channel2_reading)
            Expect.simulator_queue_empty()
          end,
          attempts: 120,
          label: "full-ring PDO flow and typed RTD decode both recover after the EL3202 heals"
        )
      end
    )
    |> Scenario.act(
      "trace captured the EL3202 mailbox fault lifecycle and later PDO disconnect",
      fn %{
           trace: trace
         } ->
        Expect.trace_sequence(trace, [
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [slave: :rtd, to: :preop, to_detail: :preop_configuration_failed]},
          {:note, "telemetry trigger matched",
           metadata: [fault: "next 30 exchanges disconnect outputs"]},
          {:note, "telemetry-triggered fault injected",
           metadata: [fault: "next 30 exchanges disconnect outputs"]},
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [slave: :outputs, to: :down, to_detail: :no_response]}
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
           metadata: [slave: :rtd, to: :preop, to_detail: :preop_configuration_failed]},
          {:event, [:ethercat, :master, :slave_fault, :changed],
           metadata: [
             slave: :rtd,
             from: :preop,
             from_detail: :preop_configuration_failed,
             to: nil
           ]}
        ])

        Expect.trace_event(trace, [:ethercat, :master, :state, :changed],
          metadata: [to: :recovering]
        )

        Expect.trace_event(trace, [:ethercat, :master, :state, :changed],
          metadata: [to: :operational]
        )
      end
    )
    |> Scenario.run()
  end

  defp assert_rtd_reading(signal_name, expected_reading) do
    assert {:ok, {reading, updated_at_us}} = EtherCAT.read_input(:rtd, signal_name)
    assert reading == expected_reading
    assert is_integer(updated_at_us)
  end

  defp rtd_sample(%{ohms: ohms} = reading) do
    value = trunc(ohms * 16)
    error = truthy_bit(reading[:error])
    overrange = truthy_bit(reading[:overrange])
    underrange = truthy_bit(reading[:underrange])
    toggle = reading[:toggle] || 0
    invalid = truthy_bit(reading[:invalid])

    <<
      0::1,
      error::1,
      0::2,
      0::2,
      overrange::1,
      underrange::1,
      toggle::1,
      invalid::1,
      0::6,
      value::16-little
    >>
  end

  defp truthy_bit(true), do: 1
  defp truthy_bit(_other), do: 0
end
