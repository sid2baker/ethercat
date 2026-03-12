defmodule EtherCAT.Integration.Simulator.ReconnectPreopMailboxAbortTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.IntegrationSupport.Drivers.{ConfiguredMailboxDevice, EK1100, EL1809, EL2809}
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  import EtherCAT.Integration.Assertions

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

    assert :ok =
             Simulator.inject_fault(
               Fault.script(
                 List.duplicate(Fault.disconnect(:mailbox), @disconnect_steps) ++
                   [Fault.mailbox_abort(:mailbox, 0x2000, 0x02, @abort_code)]
               )
             )

    assert_eventually(
      fn ->
        assert :operational = EtherCAT.state()

        assert {:preop, {:preop_configuration_failed, @failure}} =
                 SimulatorRing.fault_for(:mailbox)

        assert {:ok, %{al_state: :preop, configuration_error: @failure}} =
                 EtherCAT.slave_info(:mailbox)

        assert {:ok, %{cycle_health: :healthy}} = EtherCAT.domain_info(:main)
      end,
      220
    )

    assert :ok = EtherCAT.write_output(:outputs, :ch1, 1)

    assert_eventually(fn ->
      assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
      assert is_integer(updated_at_us)
      assert {:ok, %{value: true}} = Simulator.signal_snapshot(:outputs, :ch1)
    end)

    assert :ok = Simulator.clear_faults()

    assert_eventually(
      fn ->
        assert :operational = EtherCAT.state()
        assert nil == SimulatorRing.fault_for(:mailbox)
        assert {:ok, %{al_state: :op, configuration_error: nil}} = EtherCAT.slave_info(:mailbox)
        assert {:ok, <<1>>} = EtherCAT.upload_sdo(:mailbox, 0x2000, 0x02)
        assert {:ok, %{pending_faults: [], scheduled_faults: []}} = Simulator.info()
      end,
      220
    )
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
