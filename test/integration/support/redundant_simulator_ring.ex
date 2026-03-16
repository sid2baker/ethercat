defmodule EtherCAT.IntegrationSupport.RedundantSimulatorRing do
  @moduledoc false

  alias EtherCAT.IntegrationSupport.LinkToggle
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Slave

  @type endpoint() :: %{
          transport: :raw_redundant,
          master_primary_interface: binary(),
          master_secondary_interface: binary(),
          simulator_primary_interface: binary(),
          simulator_secondary_interface: binary()
        }

  @spec master_primary_interface() :: binary()
  def master_primary_interface do
    System.get_env("ETHERCAT_REDUNDANT_RAW_MASTER_PRIMARY_INTERFACE") || "veth-m0"
  end

  @spec simulator_primary_interface() :: binary()
  def simulator_primary_interface do
    System.get_env("ETHERCAT_REDUNDANT_RAW_SIMULATOR_PRIMARY_INTERFACE") || "veth-s0"
  end

  @spec master_secondary_interface() :: binary()
  def master_secondary_interface do
    System.get_env("ETHERCAT_REDUNDANT_RAW_MASTER_SECONDARY_INTERFACE") || "veth-m1"
  end

  @spec simulator_secondary_interface() :: binary()
  def simulator_secondary_interface do
    System.get_env("ETHERCAT_REDUNDANT_RAW_SIMULATOR_SECONDARY_INTERFACE") || "veth-s1"
  end

  @spec reset!() :: :ok
  def reset!, do: SimulatorRing.reset!()

  @spec stop_all!() :: :ok
  def stop_all!, do: SimulatorRing.stop_all!()

  @spec disconnect_primary!() :: :ok
  def disconnect_primary! do
    assert_ok!(Simulator.set_topology({:redundant, master_break: :primary}))
    LinkToggle.set_down!(master_primary_interface())
  end

  @spec reconnect_primary!() :: :ok
  def reconnect_primary! do
    LinkToggle.set_up!(master_primary_interface())
    assert_ok!(Simulator.set_topology(:redundant))
  end

  @spec start_simulator!(keyword()) :: endpoint()
  def start_simulator!(opts \\ []) do
    ring = Keyword.get(opts, :ring, :default)
    devices = Keyword.get(opts, :devices, SimulatorRing.devices(ring))
    connections = Keyword.get(opts, :connections, SimulatorRing.connections(ring))
    topology = Keyword.get(opts, :topology, :redundant)
    raw_endpoint_opts = Keyword.get(opts, :raw_endpoint_opts, [])

    raw_opts = [
      primary:
        Keyword.merge(
          [interface: simulator_primary_interface()],
          Keyword.get(raw_endpoint_opts, :primary, [])
        ),
      secondary:
        Keyword.merge(
          [interface: simulator_secondary_interface()],
          Keyword.get(raw_endpoint_opts, :secondary, [])
        )
    ]

    {:ok, _supervisor} = Simulator.start(devices: devices, raw: raw_opts, topology: topology)
    Process.sleep(20)

    Enum.each(connections, fn {source, target} ->
      assert_ok!(Slave.connect(source, target))
    end)

    %{
      transport: :raw_redundant,
      master_primary_interface: master_primary_interface(),
      master_secondary_interface: master_secondary_interface(),
      simulator_primary_interface: simulator_primary_interface(),
      simulator_secondary_interface: simulator_secondary_interface()
    }
  end

  @spec start_master!(endpoint(), keyword()) :: :ok
  def start_master!(endpoint, opts \\ []) do
    ring = Keyword.get(opts, :ring, :default)

    default_start_opts = [
      interface: endpoint.master_primary_interface,
      backup_interface: endpoint.master_secondary_interface,
      dc: nil,
      scan_stable_ms: 20,
      scan_poll_ms: 10,
      frame_timeout_ms: 20,
      domains: [SimulatorRing.default_domain()],
      slaves: SimulatorRing.slave_configs(ring, Keyword.get(opts, :slave_config_opts, []))
    ]

    start_opts =
      default_start_opts
      |> Keyword.merge(Keyword.get(opts, :start_opts, []))

    assert_ok!(start_master_with_retry(start_opts, 5))
  end

  @spec boot_operational!(keyword()) :: endpoint()
  def boot_operational!(opts \\ []) do
    reset!()
    simulator = start_simulator!(opts)
    start_master!(simulator, opts)
    assert_ok!(EtherCAT.await_operational(Keyword.get(opts, :await_operational_ms, 2_000)))
    simulator
  end

  @spec set_break_after!(pos_integer()) :: :ok
  def set_break_after!(break_after) do
    assert_ok!(Simulator.set_topology({:redundant, break_after: break_after}))
  end

  @spec heal!() :: :ok
  def heal! do
    assert_ok!(Simulator.set_topology(:redundant))
  end

  defp assert_ok!(:ok), do: :ok
  defp assert_ok!({:ok, _value}), do: :ok

  defp assert_ok!(other) do
    stop_all!()
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
