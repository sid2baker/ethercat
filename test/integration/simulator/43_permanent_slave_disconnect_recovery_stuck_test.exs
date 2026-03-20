defmodule EtherCAT.Integration.Simulator.PermanentSlaveDisconnectRecoveryStuckTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.{Expect, Scenario}
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

  # Long enough for master to enter recovery and attempt reconnect
  @disconnect_steps 60

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    SimulatorRing.boot_operational!(
      slave_config_opts: [output_health_poll_ms: 20],
      await_operational_ms: 2_500
    )

    :ok
  end

  test "master recovers after a silent PDO failure where health polling stays green" do
    # Models a hardware scenario where the slave's PDO processing fails
    # but register reads (FPRD) still work. The domain sees wkc_mismatch
    # while the slave health poll still sees the slave as healthy. The
    # regression guard here is recovery, not the stale cached API surface.

    Scenario.new()
    |> Scenario.trace()
    |> Scenario.inject_fault(
      Fault.logical_wkc_offset(:outputs, -1)
      |> Fault.next(@disconnect_steps)
    )
    |> Scenario.act("master enters recovering via domain wkc_mismatch", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:recovering)
        end,
        attempts: 80,
        label: "master enters recovering"
      )
    end)
    |> Scenario.act("master returns to operational after PDO recovers", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:operational)
          Expect.domain(:main, cycle_health: :healthy)
          Expect.simulator_queue_empty()
        end,
        attempts: 300,
        label: "master returns to operational"
      )
    end)
    |> Scenario.act("loopback I/O works after recovery", fn _ctx ->
      assert :ok = EtherCAT.Raw.write_output(:outputs, :ch1, 1)

      Expect.eventually(
        fn ->
          assert {:ok, {true, updated_at_us}} = EtherCAT.Raw.read_input(:inputs, :ch1)
          assert is_integer(updated_at_us)
        end,
        label: "loopback I/O works after recovery"
      )
    end)
    |> Scenario.run()
  end

  test "master returns to operational after a full slave disconnect and reconnect" do
    # Full disconnect: health poll FPRD also fails (wkc=0), so the slave
    # process transitions to :down and sends {:slave_down, name} to master.
    # This is the correct detection path.

    Scenario.new()
    |> Scenario.trace()
    |> Scenario.inject_fault(Fault.disconnect(:outputs) |> Fault.next(@disconnect_steps))
    |> Scenario.act("health poll detects disconnect — slave leaves :op", fn _ctx ->
      Expect.eventually(
        fn ->
          {:ok, info} = EtherCAT.Diagnostics.slave_info(:outputs)
          assert info.al_state != :op, "slave should not report :op after full disconnect"
        end,
        attempts: 40,
        label: "slave leaves :op"
      )
    end)
    |> Scenario.act("master enters recovering", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:recovering)
        end,
        attempts: 80,
        label: "master enters recovering"
      )
    end)
    |> Scenario.act("master returns to operational after slave reconnects", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:operational)
          Expect.domain(:main, cycle_health: :healthy)
          Expect.simulator_queue_empty()
        end,
        attempts: 300,
        label: "master returns to operational"
      )
    end)
    |> Scenario.act("slave is healthy and loopback I/O works", fn _ctx ->
      assert {:ok, %{al_state: :op}} = EtherCAT.Diagnostics.slave_info(:outputs)
      assert nil == SimulatorRing.fault_for(:outputs)

      assert :ok = EtherCAT.Raw.write_output(:outputs, :ch1, 1)

      Expect.eventually(
        fn ->
          assert {:ok, {true, updated_at_us}} = EtherCAT.Raw.read_input(:inputs, :ch1)
          assert is_integer(updated_at_us)
        end,
        label: "loopback I/O works after recovery"
      )
    end)
    |> Scenario.run()
  end

  test "master returns to operational after a disconnected slave reclaims its station locally" do
    # The slave disappears completely, then comes back anonymous with station 0.
    # The slave worker should probe its scan position, restore the configured
    # fixed station locally, rebuild to PREOP, and let the master resume OP.

    Scenario.new()
    |> Scenario.trace()
    |> Scenario.inject_fault(Fault.disconnect(:outputs) |> Fault.next(@disconnect_steps * 2))
    |> Scenario.act("master enters recovering after slave disconnect", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:recovering)
        end,
        attempts: 80,
        label: "master enters recovering"
      )
    end)
    |> Scenario.act("power cycle the disconnected slave so it returns anonymous", fn _ctx ->
      assert :ok = Simulator.inject_fault(Fault.power_cycle(:outputs))
      assert {:ok, %{station: 0, state: :init}} = Simulator.device_snapshot(:outputs)
    end)
    |> Scenario.act("master returns to operational after local reconnect rebuild", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:operational)
          Expect.domain(:main, cycle_health: :healthy)
          Expect.simulator_queue_empty()
        end,
        attempts: 400,
        label: "master returns to operational"
      )
    end)
    |> Scenario.act("slave is healthy and loopback I/O works", fn _ctx ->
      assert {:ok, %{al_state: :op, station: 0x1002}} = EtherCAT.Diagnostics.slave_info(:outputs)
      assert nil == SimulatorRing.fault_for(:outputs)

      assert :ok = EtherCAT.Raw.write_output(:outputs, :ch1, 1)

      Expect.eventually(
        fn ->
          assert {:ok, {true, updated_at_us}} = EtherCAT.Raw.read_input(:inputs, :ch1)
          assert is_integer(updated_at_us)
        end,
        label: "loopback I/O works after recovery"
      )
    end)
    |> Scenario.run()
  end

  test "master returns to operational after a power-cycled slave reclaims its station locally" do
    # The slave stays physically present on the ring, but power-cycling clears
    # its fixed station address. Runtime recovery should reclaim that station by
    # position and resume through the usual PREOP -> OP path.

    Scenario.new()
    |> Scenario.trace()
    |> Scenario.act("power cycle the slave (no disconnect)", fn _ctx ->
      assert :ok = Simulator.inject_fault(Fault.power_cycle(:outputs))
      assert {:ok, %{station: 0, state: :init}} = Simulator.device_snapshot(:outputs)
    end)
    |> Scenario.act("master enters recovering", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:recovering)
        end,
        attempts: 80,
        label: "master enters recovering"
      )
    end)
    |> Scenario.act("master returns to operational after local reconnect rebuild", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:operational)
          Expect.domain(:main, cycle_health: :healthy)
          Expect.simulator_queue_empty()
        end,
        attempts: 300,
        label: "master returns to operational"
      )
    end)
    |> Scenario.act("slave is healthy and loopback I/O works", fn _ctx ->
      assert {:ok, %{al_state: :op, station: 0x1002}} = EtherCAT.Diagnostics.slave_info(:outputs)
      assert nil == SimulatorRing.fault_for(:outputs)

      assert :ok = EtherCAT.Raw.write_output(:outputs, :ch1, 1)

      Expect.eventually(
        fn ->
          assert {:ok, {true, updated_at_us}} = EtherCAT.Raw.read_input(:inputs, :ch1)
          assert is_integer(updated_at_us)
        end,
        label: "loopback I/O works after recovery"
      )
    end)
    |> Scenario.run()
  end

  test "master recovers when a wkc fault fires during the reconnection window" do
    # Model the hardware race: slave disconnects, master enters recovery,
    # slave reconnects, then a brief wkc fault fires (simulates partial
    # rebuild where the slave isn't fully configured yet). The master must
    # still eventually return to operational.

    Scenario.new()
    |> Scenario.trace()
    |> Scenario.inject_fault(Fault.disconnect(:outputs) |> Fault.next(@disconnect_steps))
    |> Scenario.act("master enters recovering after slave disconnect", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:recovering)
        end,
        attempts: 80,
        label: "master enters recovering"
      )
    end)
    |> Scenario.act("slave reconnects and master begins recovering", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.simulator_queue_empty()
        end,
        attempts: 200,
        label: "disconnect fault drained"
      )

      # Inject a brief wkc fault after reconnect — simulates partial rebuild
      assert :ok = Simulator.inject_fault(Fault.logical_wkc_offset(:outputs, -1) |> Fault.next(5))
    end)
    |> Scenario.act("master returns to operational despite wkc fault during rebuild", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:operational)
          Expect.domain(:main, cycle_health: :healthy)
          Expect.simulator_queue_empty()
        end,
        attempts: 400,
        label: "master returns to operational"
      )
    end)
    |> Scenario.act("slave is healthy and loopback I/O works", fn _ctx ->
      assert {:ok, %{al_state: :op}} = EtherCAT.Diagnostics.slave_info(:outputs)
      assert nil == SimulatorRing.fault_for(:outputs)

      assert :ok = EtherCAT.Raw.write_output(:outputs, :ch1, 1)

      Expect.eventually(
        fn ->
          assert {:ok, {true, updated_at_us}} = EtherCAT.Raw.read_input(:inputs, :ch1)
          assert is_integer(updated_at_us)
        end,
        label: "loopback I/O works after recovery"
      )
    end)
    |> Scenario.run()
  end
end
