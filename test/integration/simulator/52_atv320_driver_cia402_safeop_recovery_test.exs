defmodule EtherCAT.Integration.Simulator.ATV320DriverCiA402SafeopRecoveryTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.Driver.{ATV320, EK1100}
  alias EtherCAT.Event
  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Scenario
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @setup_attempts 120
  @recovery_attempts 320
  @drive_station 0x1001

  setup do
    ensure_telemetry_started!()

    on_exit(fn -> SimulatorRing.stop_all!() end)

    boot_operational!()

    assert :ok = EtherCAT.subscribe(:drive, self())
    drain_events()

    :ok
  end

  test "ATV320 driver command flow and generic scanner mapping survive SAFEOP retreat" do
    Scenario.new()
    |> Scenario.trace()
    |> Scenario.act(
      "baseline driver surface and generic input scanner words are visible",
      fn _ctx ->
        assert {:ok, description} = EtherCAT.describe(:drive)
        assert description.device_type == :variable_speed_drive
        assert :shutdown in description.commands
        assert :switch_on in description.commands
        assert :enable_operation in description.commands
        assert :set_target_velocity in description.commands

        Expect.eventually(
          fn ->
            assert_drive_state!(:switch_on_disabled, 0x0040, actual_velocity: 0)
          end,
          attempts: @setup_attempts,
          label: "baseline ATV320 CiA402 projection settles to switch_on_disabled"
        )

        assert :ok = Simulator.set_value(:drive, :input_word_3, 0x1234)
        assert :ok = Simulator.set_value(:drive, :input_word_6, 0xABCD)

        Expect.eventually(
          fn ->
            assert {:ok, {0x1234, updated_at_us_3}} =
                     EtherCAT.Raw.read_input(:drive, :input_word_3)

            assert is_integer(updated_at_us_3)

            assert {:ok, {0xABCD, updated_at_us_6}} =
                     EtherCAT.Raw.read_input(:drive, :input_word_6)

            assert is_integer(updated_at_us_6)
          end,
          attempts: @setup_attempts,
          label: "baseline generic input scanner words are readable"
        )
      end
    )
    |> Scenario.act("generic output scanner words stage through the runtime", fn _ctx ->
      drain_events()
      assert :ok = EtherCAT.Raw.write_output(:drive, :output_word_3, 0x55AA)

      assert_receive %Event{
                       kind: :signal_changed,
                       slave: :drive,
                       signal: {:drive, :output_word_3},
                       value: 0x55AA
                     },
                     1_000

      Expect.eventually(
        fn ->
          Expect.signal(:drive, :output_word_3, value: 0x55AA)
          assert_drive_state!(:switch_on_disabled, 0x0040, output_word_3: 0x55AA)
        end,
        attempts: @setup_attempts,
        label: "generic output scanner words stage through the runtime"
      )
    end)
    |> Scenario.act(
      "CiA402 startup commands reach operation enabled and mirror velocity",
      fn _ctx ->
        command_controlword!(:shutdown, 0x0006, :ready_to_switch_on, 0x0021)
        command_controlword!(:switch_on, 0x0007, :switched_on, 0x0023)
        command_controlword!(:enable_operation, 0x000F, :operation_enabled, 0x0027)
        set_target_velocity!(1500)
      end
    )
    |> Scenario.act("SAFEOP retreat stays slave-local and heals back to AL OP", fn %{trace: trace} ->
      assert :ok = Simulator.inject_fault(Fault.retreat_to_safeop(:drive))

      Expect.eventually(
        fn ->
          Expect.trace_event(trace, [:ethercat, :slave, :health, :fault],
            measurements: [al_state: 4, error_code: 0],
            metadata: [slave: :drive, station: @drive_station]
          )

          Expect.slave_fault(:drive, {:retreated, :safeop})
          Expect.master_state(:operational)
          Expect.domain(:main, cycle_health: :healthy)
          Expect.slave(:drive, al_state: :safeop, configuration_error: nil)
        end,
        attempts: @setup_attempts,
        label: "SAFEOP retreat stays slave-local"
      )

      Expect.stays(
        fn ->
          Expect.master_state(:operational)
          Expect.domain(:main, cycle_health: :healthy)
        end,
        attempts: 10
      )

      Expect.eventually(
        fn ->
          Expect.slave_fault(:drive, nil)
          Expect.master_state(:operational)
          Expect.domain(:main, cycle_health: :healthy)
          Expect.slave(:drive, al_state: :op, configuration_error: nil)
        end,
        attempts: @recovery_attempts,
        label: "SAFEOP retreat heals back to AL OP"
      )
    end)
    |> Scenario.act("driver command flow still works after SAFEOP recovery", fn _ctx ->
      command_controlword!(:disable_voltage, 0x0000, :switch_on_disabled, 0x0040)
      command_controlword!(:shutdown, 0x0006, :ready_to_switch_on, 0x0021)
      command_controlword!(:switch_on, 0x0007, :switched_on, 0x0023)
      command_controlword!(:enable_operation, 0x000F, :operation_enabled, 0x0027)
      set_target_velocity!(900)

      Expect.eventually(
        fn ->
          assert_drive_state!(:operation_enabled, 0x0027,
            target_velocity: 900,
            actual_velocity: 900,
            output_word_3: 0x55AA
          )

          Expect.simulator_queue_empty()
        end,
        attempts: @recovery_attempts,
        label: "driver command flow still works after SAFEOP recovery"
      )
    end)
    |> Scenario.act("trace captured the SAFEOP fault lifecycle for the ATV320 slave", fn %{
                                                                                           trace:
                                                                                             trace
                                                                                         } ->
      Expect.trace_event(trace, [:ethercat, :slave, :health, :fault],
        measurements: [al_state: 4, error_code: 0],
        metadata: [slave: :drive, station: @drive_station]
      )

      Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
        metadata: [slave: :drive, to: :retreated, to_detail: :safeop]
      )

      Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
        metadata: [slave: :drive, from: :retreated, from_detail: :safeop, to: nil]
      )
    end)
    |> Scenario.run()
  end

  defp boot_operational! do
    SimulatorRing.reset!()
    simulator = SimulatorRing.start_simulator!(devices: devices(), connections: [])

    SimulatorRing.start_master!(simulator,
      start_opts: [domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}], slaves: slaves()]
    )

    assert :ok = EtherCAT.await_operational(2_500)
  end

  defp devices do
    [
      Slave.from_driver(EK1100, name: :coupler),
      Slave.from_driver(ATV320, name: :drive)
    ]
  end

  defp slaves do
    [
      %SlaveConfig{name: :coupler, driver: EK1100, process_data: :none, target_state: :op},
      %SlaveConfig{
        name: :drive,
        driver: ATV320,
        process_data: {:all, :main},
        target_state: :op,
        health_poll_ms: 20
      }
    ]
  end

  defp command_controlword!(command_name, controlword, expected_cia402_state, expected_statusword) do
    drain_events()

    assert {:ok, ref} = EtherCAT.command(:drive, command_name, %{})

    assert_receive %Event{
                     kind: :signal_changed,
                     slave: :drive,
                     signal: {:drive, :controlword},
                     value: ^controlword
                   },
                   1_000

    assert_receive %Event{
                     kind: :event,
                     slave: :drive,
                     data: {:command_accepted, ^ref}
                   },
                   1_000

    Expect.eventually(
      fn ->
        assert_drive_state!(expected_cia402_state, expected_statusword, controlword: controlword)
      end,
      attempts: @setup_attempts,
      label: "command #{inspect(command_name)} reaches #{inspect(expected_cia402_state)}"
    )

    assert_receive %Event{
                     kind: :event,
                     slave: :drive,
                     data: {:command_completed, ^ref}
                   },
                   1_000
  end

  defp set_target_velocity!(target_velocity) when is_integer(target_velocity) do
    drain_events()

    assert {:ok, ref} = EtherCAT.command(:drive, :set_target_velocity, %{value: target_velocity})

    assert_receive %Event{
                     kind: :signal_changed,
                     slave: :drive,
                     signal: {:drive, :target_velocity},
                     value: ^target_velocity
                   },
                   1_000

    assert_receive %Event{
                     kind: :event,
                     slave: :drive,
                     data: {:command_accepted, ^ref}
                   },
                   1_000

    assert_receive %Event{
                     kind: :event,
                     slave: :drive,
                     data: {:command_completed, ^ref}
                   },
                   1_000

    Expect.eventually(
      fn ->
        assert_drive_state!(:operation_enabled, 0x0027,
          target_velocity: target_velocity,
          actual_velocity: target_velocity
        )

        Expect.signal(:drive, :target_velocity, value: target_velocity)
        Expect.signal(:drive, :actual_velocity, value: target_velocity)
      end,
      attempts: @setup_attempts,
      label: "set_target_velocity mirrors target into actual velocity"
    )

    assert_receive %Event{
                     kind: :signal_changed,
                     slave: :drive,
                     signal: {:drive, :actual_velocity},
                     value: ^target_velocity
                   },
                   1_000
  end

  defp assert_drive_state!(expected_cia402_state, expected_statusword, expectations) do
    assert {:ok, snapshot} = EtherCAT.snapshot(:drive)
    assert snapshot.al_state == :op

    assert snapshot.state.cia402_state == expected_cia402_state,
           "expected CiA402 state #{inspect(expected_cia402_state)}, got #{inspect(snapshot.state)}"

    assert snapshot.state.statusword == expected_statusword,
           "expected statusword #{inspect(expected_statusword)}, got #{inspect(snapshot.state)}"

    Enum.each(Map.new(expectations), fn
      {_key, nil} ->
        :ok

      {key, expected} ->
        assert Map.fetch!(snapshot.state, key) == expected
    end)
  end

  defp ensure_telemetry_started! do
    case Application.ensure_all_started(:telemetry) do
      {:ok, _apps} -> :ok
      {:error, reason} -> raise "failed to start :telemetry: #{inspect(reason)}"
    end
  end

  defp drain_events do
    receive do
      _message -> drain_events()
    after
      0 -> :ok
    end
  end
end
