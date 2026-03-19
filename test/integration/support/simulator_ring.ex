defmodule EtherCAT.IntegrationSupport.SimulatorRing do
  @moduledoc false

  import ExUnit.CaptureLog
  alias EtherCAT.Domain.Config, as: DomainConfig

  alias EtherCAT.IntegrationSupport.Drivers.{
    EK1100,
    EL1809,
    EL2809,
    EL3202,
    SegmentedConfiguredMailboxDevice
  }

  alias EtherCAT.IntegrationSupport.{Hardware, RawSocketGuard}
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @master_ip {127, 0, 0, 1}
  @simulator_ip {127, 0, 0, 2}
  @raw_boot_attempts 3
  @default_connections [
    {{:outputs, :ch1}, {:inputs, :ch1}},
    {{:outputs, :ch16}, {:inputs, :ch16}}
  ]
  @type ring() :: :default | :hardware | :segmented
  @type transport() :: {:udp, keyword()} | {:raw, keyword()}
  @type endpoint() ::
          %{
            transport: :udp,
            port: :inet.port_number(),
            master_ip: :inet.ip_address(),
            simulator_ip: :inet.ip_address()
          }
          | %{
              transport: :raw,
              master_interface: binary(),
              simulator_interface: binary()
            }

  @spec master_ip() :: :inet.ip_address()
  def master_ip, do: @master_ip

  @spec simulator_ip() :: :inet.ip_address()
  def simulator_ip, do: @simulator_ip

  @spec raw_master_interface() :: binary()
  def raw_master_interface do
    System.get_env("ETHERCAT_RAW_MASTER_INTERFACE") || "veth-m0"
  end

  @spec raw_simulator_interface() :: binary()
  def raw_simulator_interface do
    System.get_env("ETHERCAT_RAW_SIMULATOR_INTERFACE") || "veth-s0"
  end

  @spec default_transport() :: transport()
  def default_transport do
    case System.get_env("ETHERCAT_INTEGRATION_TRANSPORT") do
      nil -> {:udp, []}
      "udp" -> {:udp, []}
      "raw" -> {:raw, []}
      other -> raise ArgumentError, "unsupported ETHERCAT_INTEGRATION_TRANSPORT=#{inspect(other)}"
    end
  end

  @spec reset!() :: :ok
  def reset! do
    capture_cleanup_logs(fn ->
      _ = EtherCAT.stop()
      _ = Simulator.stop()
      :ok
    end)
  end

  @spec stop_all!() :: :ok
  def stop_all! do
    capture_cleanup_logs(fn ->
      case EtherCAT.stop() do
        :ok -> :ok
        {:error, :already_stopped} -> :ok
      end

      :ok = Simulator.stop()
    end)
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

  @spec start_simulator!(keyword()) :: endpoint()
  def start_simulator!(opts \\ []) do
    ring = Keyword.get(opts, :ring, :default)
    devices = Keyword.get(opts, :devices, devices(ring))
    connections = Keyword.get(opts, :connections, connections(ring))
    transport = normalize_transport(Keyword.get(opts, :transport, default_transport()))

    simulator =
      case transport do
        {:udp, transport_opts} ->
          udp_opts = udp_simulator_opts(transport_opts)

          {:ok, _supervisor} = Simulator.start(devices: devices, udp: udp_opts)
          {:ok, %{udp: %{port: port}}} = Simulator.info()

          %{
            transport: :udp,
            port: port,
            master_ip: udp_master_ip(transport_opts),
            simulator_ip: udp_simulator_ip(transport_opts)
          }

        {:raw, transport_opts} ->
          RawSocketGuard.assert_available!([
            raw_master_interface(transport_opts),
            raw_simulator_interface(transport_opts)
          ])

          raw_opts =
            Keyword.merge(
              [interface: raw_simulator_interface(transport_opts)],
              Keyword.get(opts, :raw_endpoint_opts, [])
            )

          {:ok, _supervisor} = Simulator.start(devices: devices, raw: raw_opts)
          {:ok, %{raw: %{mode: :single, primary: %{interface: interface}}}} = Simulator.info()

          %{
            transport: :raw,
            simulator_interface: interface,
            master_interface: raw_master_interface(transport_opts)
          }
      end

    Process.sleep(20)

    Enum.each(connections, fn {source, target} ->
      assert_ok!(Slave.connect(source, target))
    end)

    simulator
  end

  @spec start_master!(endpoint() | :inet.port_number(), keyword()) :: :ok
  def start_master!(endpoint, opts \\ []) do
    assert_ok!(start_master(endpoint, opts))
  end

  @spec start_master(endpoint() | :inet.port_number(), keyword()) :: :ok | {:error, term()}
  def start_master(endpoint, opts \\ []) do
    ring = Keyword.get(opts, :ring, :default)

    default_start_opts = [
      dc: nil,
      scan_stable_ms: 20,
      scan_poll_ms: 10,
      frame_timeout_ms: 20,
      domains: [default_domain()],
      slaves: slave_configs(ring, Keyword.get(opts, :slave_config_opts, []))
    ]

    start_opts =
      default_start_opts
      |> Keyword.merge(start_master_transport_opts(endpoint, Keyword.get(opts, :transport)))
      |> Keyword.merge(Keyword.get(opts, :start_opts, []))

    start_master_with_retry(start_opts, 5)
  end

  @spec boot_operational!(keyword()) :: endpoint()
  def boot_operational!(opts \\ []) do
    boot_operational_with_retry(opts, boot_attempts(opts))
  end

  @spec boot_preop_ready!(keyword()) :: endpoint()
  def boot_preop_ready!(opts \\ []) do
    boot_preop_ready_with_retry(opts, boot_attempts(opts))
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

  defp boot_operational_with_retry(opts, attempts_left) when attempts_left > 0 do
    reset!()

    simulator =
      opts
      |> Keyword.get(:simulator_opts, [])
      |> Keyword.put_new(:ring, Keyword.get(opts, :ring, :default))
      |> maybe_put_transport(opts)
      |> start_simulator!()

    await_timeout_ms = Keyword.get(opts, :await_operational_ms, 2_000)

    case start_master(simulator, opts) do
      :ok ->
        case EtherCAT.await_operational(await_timeout_ms) do
          :ok ->
            simulator

          {:error, reason} ->
            retry_or_raise_boot(:operational, opts, attempts_left, reason)
        end

      {:error, reason} ->
        retry_or_raise_boot(:operational, opts, attempts_left, reason)
    end
  end

  defp boot_preop_ready_with_retry(opts, attempts_left) when attempts_left > 0 do
    reset!()

    simulator =
      opts
      |> Keyword.get(:simulator_opts, [])
      |> Keyword.put_new(:ring, Keyword.get(opts, :ring, :default))
      |> maybe_put_transport(opts)
      |> start_simulator!()

    await_timeout_ms = Keyword.get(opts, :await_running_ms, 2_000)

    case start_master(simulator, opts) do
      :ok ->
        case EtherCAT.await_running(await_timeout_ms) do
          :ok ->
            simulator

          {:error, reason} ->
            retry_or_raise_boot(:running, opts, attempts_left, reason)
        end

      {:error, reason} ->
        retry_or_raise_boot(:running, opts, attempts_left, reason)
    end
  end

  defp retry_or_raise_boot(_target, _opts, 1, reason) do
    stop_all!()
    raise ArgumentError, "expected :ok or {:ok, _}, got: #{inspect({:error, reason})}"
  end

  defp retry_or_raise_boot(target, opts, attempts_left, reason) do
    stop_all!()
    Process.sleep(20)
    boot_retry_log(target, attempts_left, reason)

    case target do
      :operational -> boot_operational_with_retry(opts, attempts_left - 1)
      :running -> boot_preop_ready_with_retry(opts, attempts_left - 1)
    end
  end

  defp boot_attempts(opts) do
    if raw_boot?(opts), do: @raw_boot_attempts, else: 1
  end

  defp raw_boot?(opts) do
    case Keyword.get(opts, :transport, default_transport()) do
      :raw -> true
      {:raw, _opts} -> true
      _other -> false
    end
  end

  defp boot_retry_log(target, attempts_left, reason) do
    IO.puts(
      :stderr,
      "[SimulatorRing] retrying raw #{target} boot after transient failure " <>
        "(attempts_left=#{attempts_left - 1}): #{inspect(reason)}"
    )
  end

  defp normalize_transport({transport, opts}) when transport in [:udp, :raw] and is_list(opts),
    do: {transport, opts}

  defp normalize_transport(:udp), do: {:udp, []}
  defp normalize_transport(:raw), do: {:raw, []}

  defp udp_simulator_opts(opts) do
    [ip: udp_simulator_ip(opts), port: Keyword.get(opts, :simulator_port, 0)]
  end

  defp udp_master_ip(opts), do: Keyword.get(opts, :master_ip, @master_ip)
  defp udp_simulator_ip(opts), do: Keyword.get(opts, :simulator_ip, @simulator_ip)

  defp raw_master_interface(opts) do
    Keyword.get(opts, :master_interface, raw_master_interface())
  end

  defp raw_simulator_interface(opts) do
    Keyword.get(opts, :simulator_interface, raw_simulator_interface())
  end

  defp capture_cleanup_logs(fun) do
    capture_log(fn ->
      result = fun.()
      Process.sleep(50)
      result
    end)
  end

  defp start_master_transport_opts(%{transport: :udp} = endpoint, _transport_override) do
    [
      transport: :udp,
      bind_ip: Map.fetch!(endpoint, :master_ip),
      host: Map.fetch!(endpoint, :simulator_ip),
      port: Map.fetch!(endpoint, :port)
    ]
  end

  defp start_master_transport_opts(%{transport: :raw} = endpoint, _transport_override) do
    [interface: Map.fetch!(endpoint, :master_interface)]
  end

  defp start_master_transport_opts(port, nil) when is_integer(port) do
    [
      transport: :udp,
      bind_ip: @master_ip,
      host: @simulator_ip,
      port: port
    ]
  end

  defp start_master_transport_opts(port, transport_override) when is_integer(port) do
    start_master_transport_opts(start_simulator_context_from_port(port, transport_override), nil)
  end

  defp start_simulator_context_from_port(port, {:udp, opts}) do
    %{
      transport: :udp,
      port: port,
      master_ip: udp_master_ip(opts),
      simulator_ip: udp_simulator_ip(opts)
    }
  end

  defp start_simulator_context_from_port(_port, {:raw, _opts}) do
    raise ArgumentError, "raw master startup requires the simulator endpoint map, not just a port"
  end

  defp start_simulator_context_from_port(port, :udp),
    do: start_simulator_context_from_port(port, {:udp, []})

  defp start_simulator_context_from_port(port, :raw),
    do: start_simulator_context_from_port(port, {:raw, []})

  defp maybe_put_transport(simulator_opts, parent_opts) do
    case Keyword.fetch(parent_opts, :transport) do
      {:ok, transport} -> Keyword.put_new(simulator_opts, :transport, transport)
      :error -> simulator_opts
    end
  end
end
