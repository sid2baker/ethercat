defmodule EtherCAT.Integration.Simulator.CombinedFaultScriptTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

  import EtherCAT.Integration.Assertions

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    SimulatorRing.boot_operational!(
      slave_config_opts: [output_health_poll_ms: 20],
      start_opts: [frame_timeout_ms: 10],
      await_operational_ms: 2_500
    )

    :ok
  end

  test "combined exchange scripts drive recovery and heal without manual fault clearing" do
    script =
      List.duplicate(Fault.drop_responses(), 6) ++
        List.duplicate(Fault.wkc_offset(-1), 4) ++
        List.duplicate(Fault.disconnect(:outputs), 30)

    assert :ok = Simulator.inject_fault(Fault.script(script))

    assert_eventually(
      fn ->
        {:ok, state} = EtherCAT.state()
        assert state in [:recovering, :operational]
      end,
      120
    )

    assert_eventually(
      fn ->
        assert {:ok, %{next_fault: nil, pending_faults: []}} = Simulator.info()
        assert {:ok, :operational} = EtherCAT.state()
        assert nil == SimulatorRing.fault_for(:outputs)
        assert {:ok, %{cycle_health: :healthy}} = EtherCAT.domain_info(:main)
        assert {:ok, %{al_state: :op}} = EtherCAT.slave_info(:outputs)
      end,
      200
    )

    assert :ok = EtherCAT.write_output(:outputs, :ch1, 1)

    assert_eventually(fn ->
      assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
      assert is_integer(updated_at_us)
      assert {:ok, %{value: true}} = Simulator.signal_snapshot(:outputs, :ch1)
    end)
  end
end
