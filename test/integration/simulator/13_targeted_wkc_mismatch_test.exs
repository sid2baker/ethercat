defmodule EtherCAT.Integration.Simulator.TargetedWKCMismatchTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.{Expect, Trace}
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

  import EtherCAT.Integration.Assertions

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    SimulatorRing.boot_operational!(
      slave_config_opts: [output_health_poll_ms: SimulatorRing.health_poll_ms()]
    )

    :ok
  end

  test "targeted logical wkc skew degrades the domain without inventing a slave-local fault" do
    trace = Trace.start_capture()
    on_exit(fn -> Trace.stop(trace) end)
    assert :ok = Simulator.inject_fault(Fault.logical_wkc_offset(:outputs, -1) |> Fault.next(12))

    # Late scheduler ticks can drain this finite script before an assertion runs.
    # Verify the transitions rather than sampling a transient live state.
    assert_eventually(fn ->
      Expect.trace_event(trace, [:ethercat, :domain, :cycle, :invalid],
        metadata: [domain: :main, reason: :wkc_mismatch, expected_wkc: 3, actual_wkc: 2]
      )

      Expect.trace_sequence(trace, [
        {:event, [:ethercat, :master, :state, :changed], metadata: [to: :recovering]},
        {:event, [:ethercat, :master, :state, :changed], metadata: [to: :operational]}
      ])
    end)

    assert_eventually(fn ->
      assert {:ok, %{next_fault: nil, pending_faults: []}} = Simulator.info()
      assert {:ok, :operational} = EtherCAT.state(SimulatorRing.session!())

      assert {:ok,
              %{
                cycle_health: :healthy,
                last_invalid_reason: {:wkc_mismatch, %{expected: 3, actual: 2}}
              }} = EtherCAT.Diagnostics.domain_info(SimulatorRing.session!(), :main)

      assert {:ok, slaves} = EtherCAT.Diagnostics.slaves(SimulatorRing.session!())
      assert Enum.all?(slaves, &is_nil(&1.fault))

      assert {:ok, %{al_state: :op}} =
               EtherCAT.Diagnostics.slave_info(SimulatorRing.session!(), :outputs)
    end)

    refute Enum.any?(Trace.snapshot(trace), fn entry ->
             match?(%{event: [:ethercat, :master, :slave_fault, :changed]}, entry)
           end)
  end
end
