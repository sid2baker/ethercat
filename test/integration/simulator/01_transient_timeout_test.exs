defmodule EtherCAT.Integration.Simulator.TransientTimeoutTest do
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

  test "domain timeout is recorded and clears when replies return" do
    assert :ok = Simulator.inject_fault(Fault.drop_responses() |> Fault.next(30))

    assert_eventually(fn ->
      assert {:ok,
              %{
                cycle_health: cycle_health,
                last_invalid_reason: :timeout,
                total_miss_count: total_miss_count
              }} =
               EtherCAT.domain_info(:main)

      assert cycle_health in [:healthy, {:invalid, :timeout}]
      assert total_miss_count > 0
      assert Enum.all?(EtherCAT.slaves(), &is_nil(&1.fault))
    end)

    assert_eventually(fn ->
      assert {:ok, %{next_fault: nil, pending_faults: []}} = Simulator.info()
      assert :operational = EtherCAT.state()

      assert {:ok, %{cycle_health: :healthy, total_miss_count: total_miss_count}} =
               EtherCAT.domain_info(:main)

      assert total_miss_count > 0
      assert Enum.all?(EtherCAT.slaves(), &is_nil(&1.fault))
    end)
  end
end
