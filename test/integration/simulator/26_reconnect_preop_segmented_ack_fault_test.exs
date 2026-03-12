defmodule EtherCAT.Integration.Simulator.ReconnectPreopSegmentedAckFaultTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain.Config, as: DomainConfig

  alias EtherCAT.IntegrationSupport.Drivers.{
    EK1100,
    EL1809,
    EL2809,
    SegmentedConfiguredMailboxDevice
  }

  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  import EtherCAT.Integration.Assertions

  @disconnect_steps 30
  @failure {:mailbox_config_failed, 0x2003, 0x01, :invalid_coe_response}

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    :ok
  end

  test "reconnect-time malformed segmented acknowledgements rerun PREOP configuration and self-heal after faults clear" do
    simulator = SimulatorRing.start_simulator!(devices: devices(), connections: connections())

    SimulatorRing.start_master!(simulator.port,
      start_opts: [domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}], slaves: slaves()]
    )

    assert :ok = EtherCAT.await_operational(2_500)

    assert :ok =
             Simulator.inject_fault(
               Fault.script(List.duplicate(Fault.disconnect(:mailbox), @disconnect_steps))
             )

    assert :ok =
             Simulator.inject_fault(
               Fault.mailbox_protocol_fault(
                 :mailbox,
                 0x2003,
                 0x01,
                 :download_segment,
                 :invalid_coe_payload
               )
               |> Fault.after_milestone(Fault.mailbox_step(:mailbox, :download_segment, 1))
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

    expected = startup_blob()

    assert_eventually(
      fn ->
        assert :operational = EtherCAT.state()
        assert nil == SimulatorRing.fault_for(:mailbox)
        assert {:ok, %{al_state: :op, configuration_error: nil}} = EtherCAT.slave_info(:mailbox)
        assert {:ok, ^expected} = EtherCAT.upload_sdo(:mailbox, 0x2003, 0x01)
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
      Slave.from_driver(SegmentedConfiguredMailboxDevice, name: :mailbox)
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
        driver: SegmentedConfiguredMailboxDevice,
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

  defp startup_blob do
    0..191
    |> Enum.map(fn value -> rem(value * 13 + 7, 256) end)
    |> :erlang.list_to_binary()
  end
end
