defmodule EtherCAT.Integration.Simulator.RedundantSecondaryDisconnectCycleBudgetTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.IntegrationSupport.{Hardware, RedundantSimulatorRing, SimulatorRing}
  alias EtherCAT.Simulator

  setup do
    _ = safe_reconnect_secondary()

    on_exit(fn ->
      _ = safe_reconnect_secondary()
      SimulatorRing.stop_all!()
    end)

    :ok
  end

  @tag :raw_socket_redundant_toggle
  test "secondary veth disconnect keeps the default 10ms ring cycling" do
    assert %{transport: :raw_redundant} =
             RedundantSimulatorRing.boot_operational!(start_opts: [frame_timeout_ms: 10])

    assert_loopback_io()

    assert :ok = RedundantSimulatorRing.disconnect_secondary!()

    Expect.eventually(fn ->
      Expect.master_state(:operational)
      Expect.domain(:main, cycle_health: :healthy)
      assert {:ok, %{topology: %{mode: :redundant, master_break: :secondary}}} = Simulator.info()
    end)

    assert_loopback_io()

    Expect.stays(fn ->
      Expect.master_state(:operational)
      Expect.domain(:main, cycle_health: :healthy)
    end)
  end

  @tag :raw_socket_redundant_toggle
  test "secondary veth disconnect keeps a 1ms ring cycling" do
    assert %{transport: :raw_redundant} =
             RedundantSimulatorRing.boot_operational!(
               start_opts: [
                 frame_timeout_ms: 10,
                 domains: [Hardware.main_domain(cycle_time_us: 1_000)]
               ]
             )

    assert_loopback_io()

    assert :ok = RedundantSimulatorRing.disconnect_secondary!()

    Expect.eventually(fn ->
      Expect.master_state(:operational)
      Expect.domain(:main, cycle_health: :healthy)
      assert {:ok, %{topology: %{mode: :redundant, master_break: :secondary}}} = Simulator.info()
    end)

    assert_loopback_io()

    Expect.stays(fn ->
      Expect.master_state(:operational)
      Expect.domain(:main, cycle_health: :healthy)
    end)
  end

  defp assert_loopback_io do
    assert :ok = EtherCAT.write_output(:outputs, :ch1, 1)
    assert :ok = EtherCAT.write_output(:outputs, :ch16, 1)

    Expect.eventually(fn ->
      Expect.master_state(:operational)
      Expect.domain(:main, cycle_health: :healthy)

      assert {:ok, {1, ch1_updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
      assert is_integer(ch1_updated_at_us)

      assert {:ok, {1, ch16_updated_at_us}} = EtherCAT.read_input(:inputs, :ch16)
      assert is_integer(ch16_updated_at_us)

      Expect.signal(:outputs, :ch1, value: true)
      Expect.signal(:outputs, :ch16, value: true)
    end)
  end

  defp safe_reconnect_secondary do
    RedundantSimulatorRing.reconnect_secondary!()
  rescue
    _error -> :ok
  end
end
