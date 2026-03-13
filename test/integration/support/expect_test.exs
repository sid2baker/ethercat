defmodule EtherCAT.Integration.ExpectTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Trace

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
end
