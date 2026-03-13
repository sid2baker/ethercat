defmodule EtherCAT.IntegrationSupport.SimulatorRing do
  @moduledoc false

  alias EtherCAT.Domain.Config, as: DomainConfig

  alias EtherCAT.IntegrationSupport.Drivers.{
    EK1100,
    EL1809,
    EL2809,
    EL3202,
    SegmentedConfiguredMailboxDevice
  }

  alias EtherCAT.IntegrationSupport.Hardware
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @master_ip {127, 0, 0, 1}
  @simulator_ip {127, 0, 0, 2}
  @default_connections [
    {{:outputs, :ch1}, {:inputs, :ch1}},
    {{:outputs, :ch16}, {:inputs, :ch16}}
  ]
  @type ring() :: :default | :hardware | :segmented

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
      {:error, :already_stopped} -> :ok
    end

    :ok = Simulator.stop()
  end

  @spec devices(ring()) :: [struct()]
  def devices(ring \\ :default)

  def devices(:default) do
    [
      Slave.from_driver(EK1100, name: :coupler),
      Slave.from_driver(EL1809, name: :inputs),
      Slave.from_driver(EL2809, name: :outputs)
    ]
  end

  def devices(:hardware) do
    devices(:default) ++ [Slave.from_driver(EL3202, name: :rtd)]
  end

  def devices(:segmented) do
    devices(:default) ++ [Slave.from_driver(SegmentedConfiguredMailboxDevice, name: :mailbox)]
  end

  @spec connections(ring()) :: [{{atom(), atom()}, {atom(), atom()}}]
  def connections(_ring \\ :default), do: @default_connections

  @spec slave_configs(ring(), keyword()) :: [SlaveConfig.t()]
  def slave_configs(ring \\ :default, opts \\ [])

  def slave_configs(:default, opts) do
    Hardware.full_ring(Keyword.put(opts, :include_rtd, false))
  end

  def slave_configs(:hardware, opts) do
    Hardware.full_ring(opts)
  end

  def slave_configs(:segmented, opts) do
    shared_health_poll_ms = Keyword.get(opts, :health_poll_ms)
    output_health_poll_ms = Keyword.get(opts, :output_health_poll_ms, shared_health_poll_ms || 20)

    mailbox_health_poll_ms =
      Keyword.get(opts, :mailbox_health_poll_ms, shared_health_poll_ms || 20)

    Hardware.full_ring(
      opts
      |> Keyword.put(:include_rtd, false)
      |> Keyword.put(:output_health_poll_ms, output_health_poll_ms)
    ) ++
      [
        %SlaveConfig{
          name: :mailbox,
          driver: SegmentedConfiguredMailboxDevice,
          process_data: :none,
          target_state: :op,
          health_poll_ms: mailbox_health_poll_ms
        }
      ]
  end

  @spec startup_blob(ring()) :: binary()
  def startup_blob(:segmented), do: SegmentedConfiguredMailboxDevice.startup_blob()

  def startup_blob(ring) do
    raise ArgumentError, "ring #{inspect(ring)} does not expose a startup blob"
  end

  @spec start_simulator!(keyword()) :: %{port: :inet.port_number()}
  def start_simulator!(opts \\ []) do
    ring = Keyword.get(opts, :ring, :default)
    devices = Keyword.get(opts, :devices, devices(ring))
    udp_opts = Keyword.get(opts, :udp, ip: @simulator_ip, port: 0)
    connections = Keyword.get(opts, :connections, connections(ring))

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
    ring = Keyword.get(opts, :ring, :default)

    default_start_opts = [
      transport: :udp,
      bind_ip: @master_ip,
      host: @simulator_ip,
      port: port,
      dc: nil,
      scan_stable_ms: 20,
      scan_poll_ms: 10,
      frame_timeout_ms: 20,
      domains: [default_domain()],
      slaves: slave_configs(ring, Keyword.get(opts, :slave_config_opts, []))
    ]

    start_opts = Keyword.merge(default_start_opts, Keyword.get(opts, :start_opts, []))
    assert_ok!(start_master_with_retry(start_opts, 5))
  end

  @spec boot_operational!(keyword()) :: %{port: :inet.port_number()}
  def boot_operational!(opts \\ []) do
    reset!()

    simulator =
      opts
      |> Keyword.get(:simulator_opts, [])
      |> Keyword.put_new(:ring, Keyword.get(opts, :ring, :default))
      |> start_simulator!()

    start_master!(simulator.port, opts)

    await_timeout_ms = Keyword.get(opts, :await_operational_ms, 2_000)
    assert_ok!(EtherCAT.await_operational(await_timeout_ms))

    simulator
  end

  @spec boot_preop_ready!(keyword()) :: %{port: :inet.port_number()}
  def boot_preop_ready!(opts \\ []) do
    reset!()

    simulator =
      opts
      |> Keyword.get(:simulator_opts, [])
      |> Keyword.put_new(:ring, Keyword.get(opts, :ring, :default))
      |> start_simulator!()

    start_master!(simulator.port, opts)

    await_timeout_ms = Keyword.get(opts, :await_running_ms, 2_000)
    assert_ok!(EtherCAT.await_running(await_timeout_ms))

    simulator
  end

  @spec default_domain() :: DomainConfig.t()
  def default_domain, do: Hardware.main_domain()

  @spec fault_for(atom()) :: term()
  def fault_for(slave_name) do
    {:ok, slaves} = EtherCAT.slaves()

    slaves
    |> Enum.find_value(fn
      %{name: ^slave_name, fault: fault} -> fault
      _slave -> nil
    end)
  end

  defp assert_ok!(:ok), do: :ok
  defp assert_ok!({:ok, _value}), do: :ok

  defp assert_ok!(other) do
    raise ArgumentError, "expected :ok or {:ok, _}, got: #{inspect(other)}"
  end

  defp start_master_with_retry(start_opts, attempts_left)

  defp start_master_with_retry(start_opts, attempts_left) when attempts_left > 1 do
    case EtherCAT.start(start_opts) do
      {:error, :eaddrinuse} ->
        Process.sleep(20)
        start_master_with_retry(start_opts, attempts_left - 1)

      other ->
        other
    end
  end

  defp start_master_with_retry(start_opts, _attempts_left), do: EtherCAT.start(start_opts)
end
