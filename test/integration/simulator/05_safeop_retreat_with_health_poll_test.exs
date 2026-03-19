defmodule EtherCAT.Integration.Simulator.SafeOpRetreatWithHealthPollTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Integration.Trace
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

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

  test "safeop retreat stays slave-local and is retried back to op", %{trace: trace} do
    assert :ok = Simulator.inject_fault(Fault.retreat_to_safeop(:outputs))

    Expect.eventually(
      fn ->
        Expect.trace_event(trace, [:ethercat, :slave, :health, :fault],
          measurements: [al_state: 4, error_code: 0],
          metadata: [slave: :outputs, station: 0x1002]
        )
      end,
      attempts: 50
    )

    Expect.eventually(
      fn ->
        Expect.slave_fault(:outputs, {:retreated, :safeop})
        Expect.master_state(:operational)
        Expect.domain(:main, cycle_health: :healthy)
        Expect.slave(:outputs, al_state: :safeop)
      end,
      attempts: 80
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
      end,
      attempts: 120
    )
  end

  test "disconnecting a slave already in safeop still transitions it to down", %{trace: trace} do
    assert :ok = Simulator.inject_fault(Fault.retreat_to_safeop(:outputs))

    Expect.eventually(
      fn ->
        Expect.trace_event(trace, [:ethercat, :slave, :health, :fault],
          measurements: [al_state: 4, error_code: 0],
          metadata: [slave: :outputs, station: 0x1002]
        )

        Expect.slave_fault(:outputs, {:retreated, :safeop})
        Expect.slave(:outputs, al_state: :safeop)
      end,
      attempts: 80,
      label: "outputs retreats to safeop first"
    )

    assert :ok = Simulator.inject_fault(Fault.disconnect(:outputs) |> Fault.next(60))

    Expect.eventually(
      fn ->
        Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
          metadata: [slave: :outputs, to: :down, to_detail: :no_response]
        )

        Expect.slave_fault(:outputs, {:down, :no_response})
        Expect.master_state([:recovering, :operational])
      end,
      attempts: 120,
      label: "safeop disconnect becomes slave down"
    )

    Expect.eventually(
      fn ->
        Expect.master_state(:operational)
        Expect.domain(:main, cycle_health: :healthy)
        Expect.slave_fault(:outputs, nil)
        Expect.slave(:outputs, al_state: :op)
        Expect.simulator_queue_empty()
      end,
      attempts: 300,
      label: "safeop disconnect later recovers"
    )
  end
end
