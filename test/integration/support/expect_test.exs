defmodule EtherCAT.Integration.ExpectTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Trace
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator.Udp
  alias EtherCAT.Simulator.Udp.Fault, as: UdpFault

  test "trace_sequence/2 asserts notes and telemetry in order" do
    trace = Trace.start_capture()

    try do
      Trace.note(trace, "first note", %{value: 1})

      Trace.handle_event(
        [:ethercat, :master, :state, :changed],
        %{},
        %{from: :operational, to: :recovering},
        trace
      )

      Trace.note(trace, "second note", %{value: 2})

      Expect.trace_sequence(trace, [
        {:note, "first note", metadata: [value: 1]},
        {:event, [:ethercat, :master, :state, :changed], metadata: [to: :recovering]},
        {:note, "second note", metadata: [value: 2]}
      ])
    after
      Trace.stop(trace)
    end
  end

  test "simulator_queue_empty/0 treats queued UDP faults as non-empty" do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    _endpoint = SimulatorRing.start_simulator!(transport: :udp)

    assert :ok = Udp.inject_fault(UdpFault.truncate())

    assert_raise ExUnit.AssertionError, fn ->
      Expect.simulator_queue_empty()
    end

    assert :ok = Udp.clear_faults()
    assert :ok = Expect.simulator_queue_empty()
  end
end
