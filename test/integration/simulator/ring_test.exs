defmodule EtherCAT.Integration.Simulator.RingTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.IntegrationSupport.Drivers.{EK1100, EL1809, EL2809}
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  import EtherCAT.Integration.Assertions

  @master_ip {127, 0, 0, 1}
  @simulator_ip {127, 0, 0, 2}

  setup do
    _ = EtherCAT.stop()

    devices = [
      Slave.from_driver(EK1100, name: :coupler),
      Slave.from_driver(EL1809, name: :inputs),
      Slave.from_driver(EL2809, name: :outputs)
    ]

    {:ok, udp_link} = Simulator.start(devices: devices, ip: @simulator_ip, port: 0)
    %{simulator: simulator, port: port} = udp_link

    Process.sleep(20)

    assert :ok = Slave.connect(simulator, {:outputs, :ch1}, {:inputs, :ch1})
    assert :ok = Slave.connect(simulator, {:outputs, :ch16}, {:inputs, :ch16})

    on_exit(fn ->
      case EtherCAT.stop() do
        :ok -> :ok
        :already_stopped -> :ok
      end

      :ok = Simulator.stop(udp_link)
    end)

    {:ok, simulator: simulator, port: port}
  end

  test "boots the simulated EK1100 -> EL1809 -> EL2809 ring to operational", %{port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 5,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: ring_slave_configs()
             )

    assert :ok = EtherCAT.await_operational(2_000)
    assert :operational = EtherCAT.state()

    assert {:ok, %{station: 0x1000, al_state: :op}} = EtherCAT.slave_info(:coupler)
    assert {:ok, %{station: 0x1001, al_state: :op}} = EtherCAT.slave_info(:inputs)
    assert {:ok, %{station: 0x1002, al_state: :op}} = EtherCAT.slave_info(:outputs)
  end

  test "reads EL1809 inputs and stages EL2809 outputs through the simulated ring", %{
    port: port,
    simulator: simulator
  } do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 5,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: ring_slave_configs()
             )

    assert :ok = EtherCAT.await_operational(2_000)

    assert :ok = EtherCAT.write_output(:outputs, :ch1, 1)
    assert :ok = EtherCAT.write_output(:outputs, :ch16, 1)

    assert_eventually(fn ->
      assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
      assert is_integer(updated_at_us)
    end)

    assert_eventually(fn ->
      assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:inputs, :ch16)
      assert is_integer(updated_at_us)
    end)

    assert_eventually(fn ->
      assert {:ok, %{value: true}} = Simulator.signal_snapshot(simulator, :outputs, :ch1)
      assert {:ok, %{value: true}} = Simulator.signal_snapshot(simulator, :outputs, :ch16)
    end)
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
end
