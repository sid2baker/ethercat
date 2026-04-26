defmodule EtherCAT.Integration.Simulator.HealthyRingTransportMatrixTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.IntegrationSupport.{RedundantSimulatorRing, SimulatorRing}
  alias EtherCAT.Raw
  alias EtherCAT.Simulator

  setup do
    on_exit(fn ->
      SimulatorRing.stop_all!()
    end)

    :ok
  end

  test "healthy ring reaches operational over UDP" do
    assert %{transport: :udp} = SimulatorRing.boot_operational!(transport: :udp)

    assert_operational_ring()
    Expect.simulator_queue_empty()
  end

  test "healthy ring exchanges cyclic PDO data over UDP" do
    assert %{transport: :udp} = SimulatorRing.boot_operational!(transport: :udp)

    assert_loopback_io()
    Expect.simulator_queue_empty()
  end

  @tag :raw_socket
  test "healthy ring reaches operational over raw transport" do
    assert %{transport: :raw} = SimulatorRing.boot_operational!(transport: :raw)

    assert_operational_ring()
    Expect.simulator_queue_empty()
  end

  @tag :raw_socket
  test "healthy ring exchanges cyclic PDO data over raw transport" do
    assert %{transport: :raw} = SimulatorRing.boot_operational!(transport: :raw)

    assert_loopback_io()
    Expect.simulator_queue_empty()
  end

  @tag :raw_socket_redundant
  test "healthy ring reaches operational over redundant raw transport" do
    assert %{transport: :raw_redundant} = RedundantSimulatorRing.boot_operational!()

    assert_operational_ring()
    Expect.simulator_queue_empty()
  end

  @tag :raw_socket_redundant
  test "redundant raw ring stays operational across a single cable break" do
    assert %{transport: :raw_redundant} = RedundantSimulatorRing.boot_operational!()

    assert :ok = RedundantSimulatorRing.set_break_after!(2)

    assert {:ok, %{topology: %{mode: :redundant, break_after: 2}}} = Simulator.info()

    assert_loopback_io()

    Expect.eventually(fn ->
      Expect.master_state(:operational)
      Expect.domain(:main, cycle_health: :healthy)
      assert {:ok, %{topology: %{mode: :redundant, break_after: 2}}} = Simulator.info()
    end)

    assert :ok = RedundantSimulatorRing.heal!()

    Expect.eventually(fn ->
      Expect.master_state(:operational)
      Expect.domain(:main, cycle_health: :healthy)
      assert {:ok, %{topology: %{mode: :redundant, break_after: nil}}} = Simulator.info()
      Expect.simulator_queue_empty()
    end)
  end

  defp assert_operational_ring do
    Expect.master_state(:operational)
    Expect.domain(:main, cycle_health: :healthy)
    Expect.slave(:coupler, station: 0x1000, al_state: :op)
    Expect.slave(:inputs, station: 0x1001, al_state: :op)
    Expect.slave(:outputs, station: 0x1002, al_state: :op)
  end

  defp assert_loopback_io do
    assert :ok = Raw.write_output(:outputs, :ch1, 1)
    assert :ok = Raw.write_output(:outputs, :ch16, 1)

    Expect.eventually(fn ->
      Expect.master_state(:operational)
      Expect.domain(:main, cycle_health: :healthy)

      assert {:ok, {true, ch1_updated_at_us}} = Raw.read_input(:inputs, :ch1)
      assert is_integer(ch1_updated_at_us)

      assert {:ok, {true, ch16_updated_at_us}} = Raw.read_input(:inputs, :ch16)
      assert is_integer(ch16_updated_at_us)

      Expect.signal(:outputs, :ch1, value: true)
      Expect.signal(:outputs, :ch16, value: true)
    end)
  end
end
