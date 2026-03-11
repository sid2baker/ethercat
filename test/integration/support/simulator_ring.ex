defmodule EtherCAT.IntegrationSupport.SimulatorRing do
  @moduledoc false

  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.IntegrationSupport.Drivers.{EK1100, EL1809, EL2809}
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @master_ip {127, 0, 0, 1}
  @simulator_ip {127, 0, 0, 2}
  @default_connections [
    {{:outputs, :ch1}, {:inputs, :ch1}},
    {{:outputs, :ch16}, {:inputs, :ch16}}
  ]

  @spec master_ip() :: :inet.ip_address()
  def master_ip, do: @master_ip

  @spec simulator_ip() :: :inet.ip_address()
  def simulator_ip, do: @simulator_ip

  @spec reset!() :: :ok
  def reset! do
    _ = EtherCAT.stop()
    _ = Simulator.stop()
    :ok
  end

  @spec stop_all!() :: :ok
  def stop_all! do
    case EtherCAT.stop() do
      :ok -> :ok
      :already_stopped -> :ok
    end

    :ok = Simulator.stop()
  end

  @spec start_simulator!(keyword()) :: %{port: :inet.port_number()}
  def start_simulator!(opts \\ []) do
    devices = Keyword.get(opts, :devices, default_devices())
    udp_opts = Keyword.get(opts, :udp, ip: @simulator_ip, port: 0)
    connections = Keyword.get(opts, :connections, @default_connections)

    {:ok, _supervisor} = Simulator.start(devices: devices, udp: udp_opts)
    {:ok, %{udp: %{port: port}}} = Simulator.info()

    Process.sleep(20)

    Enum.each(connections, fn {source, target} ->
      assert_ok!(Slave.connect(source, target))
    end)

    %{port: port}
  end

  @spec start_master!(:inet.port_number(), keyword()) :: :ok
  def start_master!(port, opts \\ []) do
    default_start_opts = [
      transport: :udp,
      bind_ip: @master_ip,
      host: @simulator_ip,
      port: port,
      dc: nil,
      scan_stable_ms: 20,
      scan_poll_ms: 10,
      frame_timeout_ms: 10,
      domains: [default_domain()],
      slaves: ring_slave_configs(Keyword.get(opts, :slave_config_opts, []))
    ]

    start_opts = Keyword.merge(default_start_opts, Keyword.get(opts, :start_opts, []))
    assert_ok!(EtherCAT.start(start_opts))
  end

  @spec boot_operational!(keyword()) :: %{port: :inet.port_number()}
  def boot_operational!(opts \\ []) do
    reset!()

    simulator = start_simulator!(Keyword.get(opts, :simulator_opts, []))
    start_master!(simulator.port, opts)

    await_timeout_ms = Keyword.get(opts, :await_operational_ms, 2_000)
    assert_ok!(EtherCAT.await_operational(await_timeout_ms))

    simulator
  end

  @spec boot_preop_ready!(keyword()) :: %{port: :inet.port_number()}
  def boot_preop_ready!(opts \\ []) do
    reset!()

    simulator = start_simulator!(Keyword.get(opts, :simulator_opts, []))
    start_master!(simulator.port, opts)

    await_timeout_ms = Keyword.get(opts, :await_running_ms, 2_000)
    assert_ok!(EtherCAT.await_running(await_timeout_ms))

    simulator
  end

  @spec ring_slave_configs(keyword()) :: [SlaveConfig.t()]
  def ring_slave_configs(opts \\ []) do
    shared_health_poll_ms = Keyword.get(opts, :health_poll_ms)

    [
      %SlaveConfig{
        name: :coupler,
        driver: EK1100,
        process_data: :none,
        target_state: :op,
        health_poll_ms: Keyword.get(opts, :coupler_health_poll_ms, shared_health_poll_ms)
      },
      %SlaveConfig{
        name: :inputs,
        driver: EL1809,
        process_data: {:all, :main},
        target_state: :op,
        health_poll_ms: Keyword.get(opts, :input_health_poll_ms, shared_health_poll_ms)
      },
      %SlaveConfig{
        name: :outputs,
        driver: EL2809,
        process_data: {:all, :main},
        target_state: :op,
        health_poll_ms: Keyword.get(opts, :output_health_poll_ms, shared_health_poll_ms)
      }
    ]
  end

  @spec default_domain() :: DomainConfig.t()
  def default_domain do
    %DomainConfig{id: :main, cycle_time_us: 10_000}
  end

  @spec fault_for(atom()) :: term()
  def fault_for(slave_name) do
    EtherCAT.slaves()
    |> Enum.find_value(fn
      %{name: ^slave_name, fault: fault} -> fault
      _slave -> nil
    end)
  end

  defp default_devices do
    [
      Slave.from_driver(EK1100, name: :coupler),
      Slave.from_driver(EL1809, name: :inputs),
      Slave.from_driver(EL2809, name: :outputs)
    ]
  end

  defp assert_ok!(:ok), do: :ok
  defp assert_ok!({:ok, _value}), do: :ok

  defp assert_ok!(other) do
    raise ArgumentError, "expected :ok or {:ok, _}, got: #{inspect(other)}"
  end
end
