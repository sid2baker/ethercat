defmodule EtherCAT.SimulatorTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Simulator

  @loopback {127, 0, 0, 1}

  setup do
    _ = Simulator.stop()

    on_exit(fn ->
      _ = Simulator.stop()
    end)

    :ok
  end

  test "stop/0 shuts down the supervised simulator runtime" do
    assert {:ok, _supervisor} =
             Simulator.start(devices: [], udp: [ip: @loopback, port: 0])

    assert {:ok, info} = Simulator.info()
    assert %{udp: %{port: port}} = info
    assert is_integer(port)
    assert port > 0

    assert :ok = Simulator.stop()
    assert {:error, :not_found} = Simulator.info()
  end

  test "stop/0 shuts down the default unsupervised simulator runtime" do
    assert {:ok, _pid} = Simulator.start_link(devices: [])
    assert {:ok, _info} = Simulator.info()

    assert :ok = Simulator.stop()
    assert {:error, :not_found} = Simulator.info()
  end

  test "setup cleanup can stop the supervised simulator runtime" do
    assert {:ok, _supervisor} =
             Simulator.start(devices: [], udp: [ip: @loopback, port: 0])

    assert {:ok, %{udp: %{port: port}}} = Simulator.info()
    assert is_integer(port)
    assert port > 0
  end

  test "info/0 reports queued exchange faults" do
    assert {:ok, _pid} = Simulator.start_link(devices: [])
    assert :ok = Simulator.inject_fault({:exchange_script, [:drop_responses, {:wkc_offset, -1}]})

    assert {:ok, %{next_fault: {:next_exchange, :drop_responses}, pending_faults: pending_faults}} =
             Simulator.info()

    assert pending_faults == [:drop_responses, {:wkc_offset, -1}]
  end

  test "info/0 reports delayed scheduled faults and drains them when due" do
    assert {:ok, _pid} = Simulator.start_link(devices: [])

    assert :ok =
             Simulator.inject_fault({:after_ms, 50, {:exchange_script, [:drop_responses]}})

    assert {:ok, %{scheduled_faults: [%{fault: {:exchange_script, [:drop_responses]}}]}} =
             Simulator.info()

    Process.sleep(80)

    assert {:ok,
            %{next_fault: {:next_exchange, :drop_responses}, pending_faults: [:drop_responses]}} =
             Simulator.info()

    assert {:ok, %{scheduled_faults: []}} = Simulator.info()
  end
end
