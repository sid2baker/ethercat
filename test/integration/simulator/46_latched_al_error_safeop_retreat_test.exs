defmodule EtherCAT.Integration.Simulator.LatchedAlErrorSafeopRetreatTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Trace
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

  @al_error_code 0x001D

  setup do
    SimulatorRing.boot_operational!(
      slave_config_opts: [output_health_poll_ms: 20],
      start_opts: [frame_timeout_ms: 10],
      await_operational_ms: 2_500
    )

    trace = Trace.start_capture()

    on_exit(fn ->
      Trace.stop(trace)
      SimulatorRing.stop_all!()
    end)

    {:ok, trace: trace}
  end

  test "latched AL error retreats to safeop without forcing master recovery", %{trace: trace} do
    assert :ok = Simulator.inject_fault(Fault.latch_al_error(:outputs, @al_error_code))

    Expect.eventually(
      fn ->
        Expect.trace_event(trace, [:ethercat, :slave, :health, :fault],
          measurements: [al_state: 8, error_code: @al_error_code],
          metadata: [slave: :outputs, station: 0x1002]
        )
      end,
      attempts: 50,
      label: "latched AL error is visible through telemetry"
    )

    Expect.eventually(
      fn ->
        Expect.slave_fault(:outputs, {:retreated, :safeop})
        Expect.master_state(:operational)
        Expect.domain(:main, cycle_health: :healthy)
        Expect.slave(:outputs, al_state: :safeop)
      end,
      attempts: 120,
      label: "latched AL error retreats to safeop without master recovery"
    )

    Expect.stays(
      fn ->
        Expect.master_state(:operational)
        Expect.domain(:main, cycle_health: :healthy)
      end,
      attempts: 10
    )

    Expect.eventually(
      fn ->
        Expect.slave_fault(:outputs, nil)
        Expect.master_state(:operational)
        Expect.slave(:outputs, al_state: :op)
        Expect.domain(:main, cycle_health: :healthy)
        Expect.simulator_queue_empty()
      end,
      attempts: 300,
      label: "latched AL error eventually returns to op"
    )
  end
end
