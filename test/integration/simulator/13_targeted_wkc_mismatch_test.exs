defmodule EtherCAT.Integration.Simulator.TargetedWKCMismatchTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

  import EtherCAT.Integration.Assertions

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    SimulatorRing.boot_operational!(slave_config_opts: [output_health_poll_ms: 20])
    :ok
  end

  test "targeted logical wkc skew degrades the domain without inventing a slave-local fault" do
    assert :ok = Simulator.inject_fault(Fault.logical_wkc_offset(:outputs, -1) |> Fault.next(12))

    assert_eventually(fn ->
      assert {:ok, :recovering} = EtherCAT.state()

      assert {:ok,
              %{
                cycle_health: {:invalid, {:wkc_mismatch, %{expected: 3, actual: 2}}},
                last_invalid_reason: {:wkc_mismatch, %{expected: 3, actual: 2}}
              }} = EtherCAT.Diagnostics.domain_info(:main)

      assert {:ok, slaves} = EtherCAT.Diagnostics.slaves()
      assert Enum.all?(slaves, &is_nil(&1.fault))
      assert {:ok, %{al_state: :op}} = EtherCAT.Diagnostics.slave_info(:outputs)
    end)

    assert_eventually(fn ->
      assert {:ok, %{next_fault: nil, pending_faults: []}} = Simulator.info()
      assert {:ok, :operational} = EtherCAT.state()
      assert {:ok, %{cycle_health: :healthy}} = EtherCAT.Diagnostics.domain_info(:main)
      assert {:ok, slaves} = EtherCAT.Diagnostics.slaves()
      assert Enum.all?(slaves, &is_nil(&1.fault))
      assert {:ok, %{al_state: :op}} = EtherCAT.Diagnostics.slave_info(:outputs)
    end)
  end
end
