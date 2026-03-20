defmodule EtherCAT.Integration.Simulator.TransientTimeoutTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Integration.Expect
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    SimulatorRing.boot_operational!()
    :ok
  end

  test "domain timeout is recorded and clears when replies return" do
    assert :ok = Simulator.inject_fault(Fault.drop_responses() |> Fault.next(30))

    Expect.eventually(fn ->
      Expect.domain(:main,
        cycle_health: [:healthy, {:invalid, :timeout}],
        last_invalid_reason: :timeout,
        total_miss_count: &(&1 > 0)
      )

      assert {:ok, slaves} = EtherCAT.Diagnostics.slaves()
      assert Enum.all?(slaves, &is_nil(&1.fault))
    end)

    Expect.eventually(fn ->
      Expect.master_state(:operational)
      Expect.domain(:main, cycle_health: :healthy, total_miss_count: &(&1 > 0))
      Expect.simulator_queue_empty()
      assert {:ok, slaves} = EtherCAT.Diagnostics.slaves()
      assert Enum.all?(slaves, &is_nil(&1.fault))
    end)
  end
end
