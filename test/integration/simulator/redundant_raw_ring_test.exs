defmodule EtherCAT.Integration.Simulator.RedundantRawRingTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.RedundantSimulatorRing
  alias EtherCAT.Simulator

  import EtherCAT.Integration.Assertions

  @tag :raw_socket_redundant
  test "redundant raw ring stays operational across a single cable break" do
    on_exit(fn ->
      RedundantSimulatorRing.stop_all!()
    end)

    _simulator = RedundantSimulatorRing.boot_operational!()
    assert {:ok, :operational} = EtherCAT.state()

    assert :ok = RedundantSimulatorRing.set_break_after!(2)
    assert {:ok, %{topology: %{mode: :redundant, break_after: 2}}} = Simulator.info()

    assert :ok = EtherCAT.write_output(:outputs, :ch1, 1)
    assert :ok = EtherCAT.write_output(:outputs, :ch16, 1)

    assert_eventually(fn ->
      assert {:ok, :operational} = EtherCAT.state()
      assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
      assert is_integer(updated_at_us)
      assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:inputs, :ch16)
      assert is_integer(updated_at_us)
      assert {:ok, %{value: true}} = Simulator.signal_snapshot(:outputs, :ch1)
      assert {:ok, %{value: true}} = Simulator.signal_snapshot(:outputs, :ch16)
    end)

    assert :ok = RedundantSimulatorRing.heal!()

    assert_eventually(fn ->
      assert {:ok, :operational} = EtherCAT.state()
      assert {:ok, %{topology: %{mode: :redundant, break_after: nil}}} = Simulator.info()
    end)
  end
end
