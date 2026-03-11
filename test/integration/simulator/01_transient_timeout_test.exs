defmodule EtherCAT.Integration.Simulator.TransientTimeoutTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator

  import EtherCAT.Integration.Assertions

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    SimulatorRing.boot_operational!()
    :ok
  end

  test "domain timeout moves the master into recovery and clears when replies return" do
    assert :ok = Simulator.inject_fault({:next_exchanges, 10, :drop_responses})

    assert_eventually(fn ->
      assert :recovering = EtherCAT.state()

      assert {:ok, %{cycle_health: {:invalid, :timeout}, last_invalid_reason: :timeout}} =
               EtherCAT.domain_info(:main)

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
