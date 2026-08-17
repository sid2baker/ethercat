defmodule EtherCAT.Integration.Simulator.ATV320ProtocolSafeopRecoveryTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.Driver.{ATV320, EK1100}
  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Scenario
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Sample
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
    assert {:ok, _initial_samples} = EtherCAT.subscribe(:drive, self())
    :ok
  end

  test "ATV320 protocol samples and scanner writes survive SAFEOP retreat" do
    Scenario.new()
    |> Scenario.trace()
    |> Scenario.act("baseline protocol description and scanner inputs are visible", fn _ctx ->
      assert {:ok, description} = EtherCAT.describe(:drive)
      assert description.device_type == :variable_speed_drive
      assert Enum.any?(description.endpoints, &(&1.signal == :controlword))
      assert Enum.any?(description.endpoints, &(&1.signal == :statusword))

      Expect.eventually(
        fn -> assert_drive_sample!(0x0040, actual_velocity: 0) end,
        attempts: @setup_attempts,
        label: "baseline ATV320 statusword sample"
      )

      assert :ok = Simulator.set_value(:drive, :input_word_3, 0x1234)
      assert :ok = Simulator.set_value(:drive, :input_word_6, 0xABCD)

      Expect.eventually(
        fn -> assert_drive_sample!(0x0040, input_word_3: 0x1234, input_word_6: 0xABCD) end,
        attempts: @setup_attempts,
        label: "generic input scanner words are sampled"
      )
    end)
    |> Scenario.act("generic scanner outputs stage through the protocol API", fn _ctx ->
      assert :ok = EtherCAT.write(:drive, :output_word_3, 0x55AA)

      Expect.eventually(
        fn -> Expect.signal(:drive, :output_word_3, value: 0x55AA) end,
        attempts: @setup_attempts,
        label: "generic output scanner word is staged"
      )
    end)
    |> Scenario.act("explicit controlword writes reach operation enabled", fn _ctx ->
      write_controlword!(0x0006, 0x0021)
      write_controlword!(0x0007, 0x0023)
      write_controlword!(0x000F, 0x0027)
      write_target_velocity!(1500)
    end)
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
    |> Scenario.act("protocol writes and samples still work after recovery", fn _ctx ->
      write_controlword!(0x0000, 0x0040)
      write_controlword!(0x0006, 0x0021)
      write_controlword!(0x0007, 0x0023)
      write_controlword!(0x000F, 0x0027)
      write_target_velocity!(900)

      Expect.eventually(
        fn ->
          assert_drive_sample!(0x0027, actual_velocity: 900)
          Expect.signal(:drive, :target_velocity, value: 900)
          Expect.signal(:drive, :output_word_3, value: 0x55AA)
          Expect.simulator_queue_empty()
        end,
        attempts: @recovery_attempts,
        label: "protocol flow works after SAFEOP recovery"
      )
    end)
    |> Scenario.act("trace captured the SAFEOP fault lifecycle", fn %{trace: trace} ->
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

  defp write_controlword!(controlword, expected_statusword) do
    assert :ok = EtherCAT.write(:drive, :controlword, controlword)

    Expect.eventually(
      fn ->
        Expect.signal(:drive, :controlword, value: controlword)
        assert_drive_sample!(expected_statusword)
      end,
      attempts: @setup_attempts,
      label:
        "controlword #{inspect(controlword)} reaches statusword #{inspect(expected_statusword)}"
    )
  end

  defp write_target_velocity!(target_velocity) do
    assert :ok = EtherCAT.write(:drive, :target_velocity, target_velocity)

    Expect.eventually(
      fn ->
        Expect.signal(:drive, :target_velocity, value: target_velocity)
        Expect.signal(:drive, :actual_velocity, value: target_velocity)
        assert_drive_sample!(0x0027, actual_velocity: target_velocity)
      end,
      attempts: @setup_attempts,
      label: "target velocity is reflected in protocol input"
    )
  end

  defp assert_drive_sample!(expected_statusword, expectations \\ []) do
    assert {:ok,
            %Sample{slave: :drive, domain: :main, inputs: %{statusword: ^expected_statusword}} =
              sample} = EtherCAT.sample(:drive, :main)

    Enum.each(expectations, fn {signal, expected} ->
      assert Map.get(sample.inputs, signal) == expected
    end)
  end

  defp ensure_telemetry_started! do
    case Application.ensure_all_started(:telemetry) do
      {:ok, _apps} -> :ok
      {:error, reason} -> raise "failed to start :telemetry: #{inspect(reason)}"
    end
  end
end
