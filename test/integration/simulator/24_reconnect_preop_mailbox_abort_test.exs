defmodule EtherCAT.Integration.Simulator.ReconnectPreopMailboxAbortTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Scenario
  alias EtherCAT.IntegrationSupport.Drivers.{ConfiguredMailboxDevice, EK1100, EL1809, EL2809}
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @abort_code 0x0601_0002
  @disconnect_steps 30
  @failure {:mailbox_config_failed, 0x2000, 0x02, {:sdo_abort, 0x2000, 0x02, @abort_code}}

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    :ok
  end

  test "reconnect-time mailbox aborts rerun PREOP configuration and self-heal after faults clear" do
    simulator = SimulatorRing.start_simulator!(devices: devices(), connections: connections())

    SimulatorRing.start_master!(simulator.port,
      start_opts: [domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}], slaves: slaves()]
    )

    assert :ok = EtherCAT.await_operational(2_500)

    Scenario.new()
    |> Scenario.trace()
    |> Scenario.inject_fault(
      Fault.script(
        List.duplicate(Fault.disconnect(:mailbox), @disconnect_steps) ++
          [Fault.mailbox_abort(:mailbox, 0x2000, 0x02, @abort_code)]
      )
    )
    |> Scenario.expect_eventually(
      "mailbox falls back to PREOP while cyclic runtime stays healthy",
      fn _ctx ->
        Expect.master_state(:operational)
        Expect.slave_fault(:mailbox, {:preop, {:preop_configuration_failed, @failure}})
        Expect.slave(:mailbox, al_state: :preop, configuration_error: @failure)
        Expect.domain(:main, cycle_health: :healthy)
      end,
      attempts: 220
    )
    |> Scenario.act("write output ch1 high", fn _ctx ->
      assert :ok = EtherCAT.write_output(:outputs, :ch1, 1)
    end)
    |> Scenario.expect_eventually("pdo flow still works during mailbox fault", fn _ctx ->
      assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
      assert is_integer(updated_at_us)
      Expect.signal(:outputs, :ch1, value: true)
    end)
    |> Scenario.clear_faults()
    |> Scenario.expect_eventually(
      "mailbox self-heals after fault clear",
      fn _ctx ->
        Expect.master_state(:operational)
        Expect.slave_fault(:mailbox, nil)
        Expect.slave(:mailbox, al_state: :op, configuration_error: nil)
        assert {:ok, <<1>>} = EtherCAT.upload_sdo(:mailbox, 0x2000, 0x02)
        Expect.simulator_queue_empty()
      end,
      attempts: 220
    )
    |> Scenario.run()
  end

  defp devices do
    [
      Slave.from_driver(EK1100, name: :coupler),
      Slave.from_driver(EL1809, name: :inputs),
      Slave.from_driver(EL2809, name: :outputs),
      Slave.from_driver(ConfiguredMailboxDevice, name: :mailbox)
    ]
  end

  defp slaves do
    [
      %SlaveConfig{name: :coupler, driver: EK1100, process_data: :none, target_state: :op},
      %SlaveConfig{
        name: :inputs,
        driver: EL1809,
        process_data: {:all, :main},
        target_state: :op
      },
      %SlaveConfig{
        name: :outputs,
        driver: EL2809,
        process_data: {:all, :main},
        target_state: :op,
        health_poll_ms: 20
      },
      %SlaveConfig{
        name: :mailbox,
        driver: ConfiguredMailboxDevice,
        process_data: :none,
        target_state: :op,
        health_poll_ms: 20
      }
    ]
  end

  defp connections do
    [
      {{:outputs, :ch1}, {:inputs, :ch1}},
      {{:outputs, :ch16}, {:inputs, :ch16}}
    ]
  end
end
