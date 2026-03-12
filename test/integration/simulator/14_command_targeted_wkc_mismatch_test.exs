defmodule EtherCAT.Integration.Simulator.CommandTargetedWKCMismatchTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Integration.Trace
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

  setup do
    SimulatorRing.boot_operational!(
      slave_config_opts: [output_health_poll_ms: 20],
      await_operational_ms: 2_500
    )

    trace = Trace.start_capture()

    on_exit(fn ->
      Trace.stop(trace)
      SimulatorRing.stop_all!()
    end)

    {:ok, trace: trace}
  end

  test "command-targeted fprd skew drives slave-down recovery while logical PDO traffic stays healthy",
       %{trace: trace} do
    assert :ok = Simulator.inject_fault(Fault.command_wkc_offset(:fprd, -1) |> Fault.next(100))

    Expect.eventually(
      fn ->
        Expect.trace_event(trace, [:ethercat, :slave, :down],
          metadata: [slave: :outputs, station: 0x1002]
        )
      end,
      attempts: 80
    )

    Expect.eventually(
      fn ->
        Expect.domain(:main, cycle_health: :healthy)
        Expect.slave(:outputs, al_state: :op)
      end,
      attempts: 120
    )

    Expect.eventually(
      fn ->
        Expect.simulator_queue_empty()
        Expect.master_state(:operational)
        Expect.slave_fault(:outputs, nil)
        Expect.domain(:main, cycle_health: :healthy)
        Expect.slave(:outputs, al_state: :op)
      end,
      attempts: 200
    )
  end
end
