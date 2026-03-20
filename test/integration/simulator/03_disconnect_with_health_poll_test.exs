defmodule EtherCAT.Integration.Simulator.DisconnectWithHealthPollTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

  import EtherCAT.Integration.Assertions

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    SimulatorRing.boot_operational!(
      slave_config_opts: [output_health_poll_ms: 20],
      await_operational_ms: 2_500
    )

    :ok
  end

  test "disconnecting a PDO slave trips slave-down recovery when health polling is enabled" do
    assert :ok = Simulator.inject_fault(Fault.disconnect(:outputs) |> Fault.next(30))

    assert_eventually(
      fn ->
        {:ok, state} = EtherCAT.state()
        assert state in [:recovering, :operational]
      end,
      80
    )

    assert_eventually(
      fn ->
        assert {:ok, %{next_fault: nil, pending_faults: []}} = Simulator.info()
        assert {:ok, :operational} = EtherCAT.state()
        assert nil == SimulatorRing.fault_for(:outputs)
        assert {:ok, %{al_state: :op}} = EtherCAT.Diagnostics.slave_info(:outputs)
      end,
      120
    )

    assert :ok = EtherCAT.Raw.write_output(:outputs, :ch1, 1)

    assert_eventually(fn ->
      assert {:ok, {true, updated_at_us}} = EtherCAT.Raw.read_input(:inputs, :ch1)
      assert is_integer(updated_at_us)
      assert {:ok, %{value: true}} = Simulator.signal_snapshot(:outputs, :ch1)
    end)
  end

  test "disconnecting a PDO slave eventually makes cached input reads stale" do
    assert_eventually(fn ->
      assert {:ok, {_value, refreshed_at_us}} = EtherCAT.Raw.read_input(:inputs, :ch1)
      assert is_integer(refreshed_at_us)
    end)

    assert :ok = Simulator.inject_fault(Fault.disconnect(:outputs) |> Fault.next(120))

    assert_eventually(
      fn ->
        assert {:error,
                {:stale,
                 %{
                   refreshed_at_us: refreshed_at_us,
                   age_us: age_us,
                   stale_after_us: stale_after_us
                 }}} =
                 EtherCAT.Raw.read_input(:inputs, :ch1)

        assert is_integer(refreshed_at_us)
        assert is_integer(age_us)
        assert is_integer(stale_after_us)
        assert age_us > stale_after_us
      end,
      80
    )
  end
end
