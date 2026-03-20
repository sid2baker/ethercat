defmodule EtherCAT.Integration.Simulator.EmbeddedMilestoneFaultScriptTest do
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

  test "fault scripts can embed milestone waits between exchange and slave-local steps" do
    fault_script =
      List.duplicate(Fault.drop_responses(), 6) ++
        List.duplicate(Fault.wkc_offset(-1), 4) ++
        [Fault.wait_for(Fault.healthy_polls(:outputs, 12)), Fault.retreat_to_safeop(:outputs)]

    assert :ok = Simulator.inject_fault(Fault.script(fault_script))

    assert_eventually(
      fn ->
        assert {:ok, :recovering} = EtherCAT.state()
      end,
      80
    )

    assert_eventually(
      fn ->
        assert {:ok,
                %{
                  pending_faults: [],
                  scheduled_faults: [
                    %{
                      fault: {:fault_script, [{:retreat_to_safeop, :outputs}]},
                      waiting_on: {:healthy_polls, :outputs, 12},
                      remaining: remaining
                    }
                  ]
                }} = Simulator.info()

        assert remaining > 0
        assert remaining < 12
        assert {:ok, :operational} = EtherCAT.state()
        assert nil == SimulatorRing.fault_for(:outputs)
      end,
      180
    )

    assert_eventually(
      fn ->
        assert {:retreated, :safeop} = SimulatorRing.fault_for(:outputs)
        assert {:ok, :operational} = EtherCAT.state()
        assert {:ok, %{al_state: :safeop}} = EtherCAT.Diagnostics.slave_info(:outputs)
      end,
      220
    )

    assert_eventually(
      fn ->
        assert {:ok, %{scheduled_faults: []}} = Simulator.info()
        assert nil == SimulatorRing.fault_for(:outputs)
        assert {:ok, :operational} = EtherCAT.state()
        assert {:ok, %{al_state: :op}} = EtherCAT.Diagnostics.slave_info(:outputs)
        assert {:ok, %{cycle_health: :healthy}} = EtherCAT.Diagnostics.domain_info(:main)
      end,
      220
    )

    assert :ok = EtherCAT.Raw.write_output(:outputs, :ch1, 1)

    assert_eventually(fn ->
      assert {:ok, {true, updated_at_us}} = EtherCAT.Raw.read_input(:inputs, :ch1)
      assert is_integer(updated_at_us)
      assert {:ok, %{value: true}} = Simulator.signal_snapshot(:outputs, :ch1)
    end)
  end
end
