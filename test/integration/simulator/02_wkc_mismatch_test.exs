defmodule EtherCAT.Integration.Simulator.WKCMismatchTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

  import EtherCAT.Integration.Assertions

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    SimulatorRing.boot_operational!()
    :ok
  end

  test "wkc mismatch is retained without inventing a slave-local fault" do
    assert :ok = Simulator.inject_fault(Fault.wkc_offset(-1) |> Fault.next(6))

    assert_eventually(fn ->
      assert {:ok,
              %{
                total_miss_count: total_miss_count,
                last_invalid_reason: {:wkc_mismatch, %{expected: 3, actual: 2}}
              }} = EtherCAT.Diagnostics.domain_info(SimulatorRing.session!(), :main)

      assert total_miss_count > 0
      assert {:ok, slaves} = EtherCAT.Diagnostics.slaves(SimulatorRing.session!())
      assert Enum.all?(slaves, &is_nil(&1.fault))
    end)

    assert_eventually(fn ->
      assert {:ok, %{next_fault: nil, pending_faults: []}} = Simulator.info()
      assert {:ok, :operational} = EtherCAT.state(SimulatorRing.session!())

      assert {:ok, %{cycle_health: :healthy}} =
               EtherCAT.Diagnostics.domain_info(SimulatorRing.session!(), :main)

      assert {:ok, slaves} = EtherCAT.Diagnostics.slaves(SimulatorRing.session!())
      assert Enum.all?(slaves, &is_nil(&1.fault))
    end)
  end
end
