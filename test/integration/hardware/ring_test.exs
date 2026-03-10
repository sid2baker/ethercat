defmodule EtherCAT.Integration.Hardware.RingTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.IntegrationSupport.Drivers.{EK1100, EL1809, EL2809}
  alias EtherCAT.IntegrationSupport.Hardware
  alias EtherCAT.Slave.Config, as: SlaveConfig

  import EtherCAT.Integration.Assertions

  @moduletag :hardware

  setup do
    _ = EtherCAT.stop()

    on_exit(fn ->
      case EtherCAT.stop() do
        :ok -> :ok
        :already_stopped -> :ok
      end
    end)

    {:ok, interface: interface_or_skip()}
  end

  test "boots the EK1100 -> EL1809 -> EL2809 ring to operational", %{interface: interface} do
    assert :ok =
             EtherCAT.start(
               interface: interface,
               dc: nil,
               scan_stable_ms: 50,
               scan_poll_ms: 20,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: ring_slave_configs()
             )

    assert :ok = EtherCAT.await_operational(5_000)
    assert :operational = EtherCAT.state()

    assert {:ok, %{station: 0x1000, al_state: :op}} = EtherCAT.slave_info(:coupler)
    assert {:ok, %{station: 0x1001, al_state: :op}} = EtherCAT.slave_info(:inputs)
    assert {:ok, %{station: 0x1002, al_state: :op}} = EtherCAT.slave_info(:outputs)
  end

  test "reads EL1809 inputs and stages EL2809 outputs on the real ring", %{interface: interface} do
    assert :ok =
             EtherCAT.start(
               interface: interface,
               dc: nil,
               scan_stable_ms: 50,
               scan_poll_ms: 20,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: ring_slave_configs()
             )

    assert :ok = EtherCAT.await_operational(5_000)

    assert_eventually(fn ->
      assert {:ok, {value, updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
      assert is_integer(value)
      assert is_integer(updated_at_us)
    end)

    assert :ok = EtherCAT.write_output(:outputs, :ch1, 1)
    assert :ok = EtherCAT.write_output(:outputs, :ch16, 0)
  end

  defp ring_slave_configs do
    [
      %SlaveConfig{
        name: :coupler,
        driver: EK1100,
        process_data: :none,
        target_state: :op
      },
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
        target_state: :op
      }
    ]
  end

  defp interface_or_skip do
    case Hardware.interface() do
      {:ok, interface} -> interface
      {:error, reason} -> flunk(reason)
    end
  end
end
