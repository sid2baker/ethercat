defmodule EtherCAT.Integration.Simulator.RingTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator

  import EtherCAT.Integration.Assertions

  setup do
    SimulatorRing.reset!()
    %{port: port} = SimulatorRing.start_simulator!()

    on_exit(fn ->
      SimulatorRing.stop_all!()
    end)

    {:ok, port: port}
  end

  test "boots the simulated EK1100 -> EL1809 -> EL2809 ring to operational", %{port: port} do
    assert :ok = SimulatorRing.start_master!(port)

    assert :ok = EtherCAT.await_operational(2_000)
    assert :operational = EtherCAT.state()

    assert {:ok, %{station: 0x1000, al_state: :op}} = EtherCAT.slave_info(:coupler)
    assert {:ok, %{station: 0x1001, al_state: :op}} = EtherCAT.slave_info(:inputs)
    assert {:ok, %{station: 0x1002, al_state: :op}} = EtherCAT.slave_info(:outputs)
  end

  test "reads EL1809 inputs and stages EL2809 outputs through the simulated ring", %{port: port} do
    assert :ok = SimulatorRing.start_master!(port)

    assert :ok = EtherCAT.await_operational(2_000)

    assert :ok = EtherCAT.write_output(:outputs, :ch1, 1)
    assert :ok = EtherCAT.write_output(:outputs, :ch16, 1)

    assert_eventually(fn ->
      assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
      assert is_integer(updated_at_us)
    end)

    assert_eventually(fn ->
      assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:inputs, :ch16)
      assert is_integer(updated_at_us)
    end)

    assert_eventually(fn ->
      assert {:ok, %{value: true}} = Simulator.signal_snapshot(:outputs, :ch1)
      assert {:ok, %{value: true}} = Simulator.signal_snapshot(:outputs, :ch16)
    end)
  end
end
