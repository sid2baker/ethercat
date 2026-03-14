defmodule EtherCAT.Integration.Simulator.CriticalPdoReconnectPreopSelfHealTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Scenario
  alias EtherCAT.IntegrationSupport.Drivers.{ConfiguredProcessMailboxDevice, EK1100}
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @disconnect_steps 30
  @failure {:mailbox_config_failed, 0x2003, 0x01, :response_timeout}

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    boot_operational!()
    :ok
  end

  test "a PDO slave that heals after reconnect PREOP failure lets master recovery finish" do
    expected = ConfiguredProcessMailboxDevice.startup_blob()

    fault_script =
      List.duplicate(Fault.disconnect(:combo), @disconnect_steps) ++
        [
          Fault.wait_for(Fault.mailbox_step(:combo, :download_segment, 1)),
          Fault.mailbox_protocol_fault(
            :combo,
            0x2003,
            0x01,
            :download_segment,
            :drop_response
          )
        ]

    Scenario.new()
    |> Scenario.trace()
    |> Scenario.inject_fault(Fault.script(fault_script))
    |> Scenario.act(
      "the reconnecting PDO slave retains the PREOP configuration failure",
      fn _ctx ->
        Expect.eventually(
          fn ->
            Expect.master_state(:recovering)
            Expect.slave_fault(:combo, {:preop, {:preop_configuration_failed, @failure}})
            Expect.slave(:combo, al_state: :preop, configuration_error: @failure)
          end,
          attempts: 220,
          label: "the reconnecting PDO slave retains the PREOP configuration failure"
        )
      end
    )
    |> Scenario.act(
      "the later retry clears both the slave fault and the master recovery state",
      fn _ctx ->
        Expect.eventually(
          fn ->
            Expect.master_state(:operational)
            Expect.domain(:main, cycle_health: :healthy)
            Expect.slave_fault(:combo, nil)
            Expect.slave(:combo, al_state: :op, configuration_error: nil)
            assert {:ok, ^expected} = EtherCAT.upload_sdo(:combo, 0x2003, 0x01)
            Expect.simulator_queue_empty()
          end,
          attempts: 360,
          label: "the later retry clears both the slave fault and the master recovery state"
        )
      end
    )
    |> Scenario.act("trace captured recovery entry, retained PREOP fault, and final resume", fn %{
                                                                                                  trace:
                                                                                                    trace
                                                                                                } ->
      Expect.trace_event(trace, [:ethercat, :master, :state, :changed],
        metadata: [to: :recovering]
      )

      Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
        metadata: [slave: :combo, to: :preop, to_detail: :preop_configuration_failed]
      )

      Expect.trace_event(trace, [:ethercat, :master, :slave_fault, :changed],
        metadata: [
          slave: :combo,
          from: :preop,
          from_detail: :preop_configuration_failed,
          to: nil
        ]
      )

      Expect.trace_event(trace, [:ethercat, :master, :state, :changed],
        metadata: [to: :operational]
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
      Slave.from_driver(ConfiguredProcessMailboxDevice, name: :combo)
    ]
  end

  defp slaves do
    [
      %SlaveConfig{name: :coupler, driver: EK1100, process_data: :none, target_state: :op},
      %SlaveConfig{
        name: :combo,
        driver: ConfiguredProcessMailboxDevice,
        process_data: {:all, :main},
        target_state: :op,
        health_poll_ms: 20
      }
    ]
  end
end
