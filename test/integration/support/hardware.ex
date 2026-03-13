defmodule EtherCAT.IntegrationSupport.Hardware do
  @moduledoc false

  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.IntegrationSupport.Drivers.{EK1100, EL1809, EL2809, EL3202}
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @default_udp_port 0x88A4

  @type transport_profile :: %{
          id: :raw | :udp | :raw_redundant,
          label: binary(),
          transport: :raw | :udp,
          redundant?: boolean(),
          start_opts: keyword()
        }

  @spec interface() :: {:ok, binary()} | {:error, binary()}
  def interface do
    env_interface(
      "ETHERCAT_INTERFACE",
      "set ETHERCAT_INTERFACE to run hardware integration tests"
    )
  end

  @spec interface!() :: binary()
  def interface! do
    case interface() do
      {:ok, interface} -> interface
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec backup_interface() :: {:ok, binary()} | {:error, binary()}
  def backup_interface do
    env_interface(
      "ETHERCAT_BACKUP_INTERFACE",
      "set ETHERCAT_BACKUP_INTERFACE to run redundant hardware integration tests"
    )
  end

  @spec backup_interface!() :: binary()
  def backup_interface! do
    case backup_interface() do
      {:ok, interface} -> interface
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec single_link_profiles() :: [transport_profile()]
  def single_link_profiles do
    [raw_profile(), udp_profile()]
    |> Enum.reject(&is_nil/1)
  end

  @spec redundant_profiles() :: [transport_profile()]
  def redundant_profiles do
    case {interface(), backup_interface()} do
      {{:ok, primary}, {:ok, secondary}} ->
        [
          %{
            id: :raw_redundant,
            label: "redundant raw",
            transport: :raw,
            redundant?: true,
            start_opts: [interface: primary, backup_interface: secondary]
          }
        ]

      _ ->
        []
    end
  end

  @spec start_opts(transport_profile()) :: keyword()
  def start_opts(%{start_opts: start_opts}), do: start_opts

  @spec expected_bus_link(transport_profile()) :: binary()
  def expected_bus_link(%{id: :raw, start_opts: start_opts}) do
    Keyword.fetch!(start_opts, :interface)
  end

  def expected_bus_link(%{id: :udp, start_opts: start_opts}) do
    host = Keyword.fetch!(start_opts, :host)
    port = Keyword.fetch!(start_opts, :port)
    "#{:inet.ntoa(host)}:#{port}"
  end

  def expected_bus_link(%{id: :raw_redundant, start_opts: start_opts}) do
    primary = Keyword.fetch!(start_opts, :interface)
    secondary = Keyword.fetch!(start_opts, :backup_interface)
    "#{primary}|#{secondary}"
  end

  @spec single_link_configuration_message() :: binary()
  def single_link_configuration_message do
    [
      "configure at least one hardware transport to run these tests:",
      "  raw: ETHERCAT_INTERFACE=<eth-iface>",
      "  udp: ETHERCAT_UDP_HOST=<ip> [ETHERCAT_UDP_BIND_IP=<ip>] [ETHERCAT_UDP_PORT=34980]",
      "if both raw and UDP are configured, the ring suite runs once per transport"
    ]
    |> Enum.join("\n")
  end

  @spec main_domain(keyword()) :: DomainConfig.t()
  def main_domain(opts \\ []) do
    build_domain([id: :main, cycle_time_us: 10_000], opts)
  end

  @spec coupler(keyword()) :: SlaveConfig.t()
  def coupler(opts \\ []) do
    build_slave([name: :coupler, driver: EK1100, process_data: :none, target_state: :op], opts)
  end

  @spec inputs(keyword()) :: SlaveConfig.t()
  def inputs(opts \\ []) do
    build_slave(
      [name: :inputs, driver: EL1809, process_data: {:all, :main}, target_state: :op],
      opts
    )
  end

  @spec outputs(keyword()) :: SlaveConfig.t()
  def outputs(opts \\ []) do
    build_slave(
      [name: :outputs, driver: EL2809, process_data: {:all, :main}, target_state: :op],
      opts
    )
  end

  @spec rtd(keyword()) :: SlaveConfig.t()
  def rtd(opts \\ []) do
    build_slave(
      [name: :rtd, driver: EL3202, process_data: {:all, :main}, target_state: :op],
      opts
    )
  end

  @spec full_ring(keyword()) :: [SlaveConfig.t()]
  def full_ring(opts \\ []) do
    include_rtd = Keyword.get(opts, :include_rtd, true)
    shared_health_poll_ms = Keyword.get(opts, :health_poll_ms)

    coupler_opts =
      slave_opts(
        Keyword.get(opts, :coupler, []),
        Keyword.get(opts, :coupler_health_poll_ms, shared_health_poll_ms)
      )

    inputs_opts =
      slave_opts(
        Keyword.get(opts, :inputs, []),
        Keyword.get(opts, :input_health_poll_ms, shared_health_poll_ms)
      )

    outputs_opts =
      slave_opts(
        Keyword.get(opts, :outputs, []),
        Keyword.get(opts, :output_health_poll_ms, shared_health_poll_ms)
      )

    rtd_opts =
      slave_opts(
        Keyword.get(opts, :rtd, []),
        Keyword.get(opts, :rtd_health_poll_ms, shared_health_poll_ms)
      )

    [coupler(coupler_opts), inputs(inputs_opts), outputs(outputs_opts)] ++
      if(include_rtd, do: [rtd(rtd_opts)], else: [])
  end

  defp build_domain(defaults, opts) do
    DomainConfig
    |> struct!(Keyword.merge(defaults, opts))
  end

  defp build_slave(defaults, opts) do
    SlaveConfig
    |> struct!(Keyword.merge(defaults, opts))
  end

  defp slave_opts(opts, nil), do: opts

  defp slave_opts(opts, health_poll_ms),
    do: Keyword.put_new(opts, :health_poll_ms, health_poll_ms)

  defp raw_profile do
    case interface() do
      {:ok, interface} ->
        %{
          id: :raw,
          label: "raw",
          transport: :raw,
          redundant?: false,
          start_opts: [interface: interface]
        }

      {:error, _reason} ->
        nil
    end
  end

  defp udp_profile do
    case System.get_env("ETHERCAT_UDP_HOST") do
      nil ->
        nil

      "" ->
        nil

      host ->
        start_opts =
          [transport: :udp, host: parse_ip!(host, "ETHERCAT_UDP_HOST"), port: udp_port()]
          |> maybe_put_udp_bind_ip()

        %{
          id: :udp,
          label: "udp",
          transport: :udp,
          redundant?: false,
          start_opts: start_opts
        }
    end
  end

  defp maybe_put_udp_bind_ip(start_opts) do
    case udp_bind_ip() do
      :none -> start_opts
      {:ok, bind_ip} -> Keyword.put(start_opts, :bind_ip, bind_ip)
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp udp_bind_ip do
    case System.get_env("ETHERCAT_UDP_BIND_IP") do
      bind_ip when is_binary(bind_ip) and byte_size(bind_ip) > 0 ->
        {:ok, parse_ip!(bind_ip, "ETHERCAT_UDP_BIND_IP")}

      _ ->
        maybe_interface_bind_ip()
    end
  end

  defp maybe_interface_bind_ip do
    case System.get_env("ETHERCAT_INTERFACE") do
      interface when is_binary(interface) and byte_size(interface) > 0 ->
        with {:ok, resolved_interface} <- interface(),
             {:ok, bind_ip} <- interface_ipv4(resolved_interface) do
          {:ok, bind_ip}
        end

      _ ->
        :none
    end
  end

  defp udp_port do
    case System.get_env("ETHERCAT_UDP_PORT") do
      nil ->
        @default_udp_port

      "" ->
        @default_udp_port

      raw_port ->
        case Integer.parse(raw_port) do
          {port, ""} when port > 0 and port <= 65_535 ->
            port

          _ ->
            raise ArgumentError, "ETHERCAT_UDP_PORT=#{inspect(raw_port)} is not a valid UDP port"
        end
    end
  end

  defp interface_ipv4(interface) do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        case List.keyfind(ifaddrs, String.to_charlist(interface), 0) do
          {_, attrs} ->
            case Enum.find(Keyword.get_values(attrs, :addr), &(tuple_size(&1) == 4)) do
              nil ->
                {:error,
                 "interface #{inspect(interface)} has no IPv4 address; set ETHERCAT_UDP_BIND_IP to run UDP hardware tests"}

              ip ->
                {:ok, ip}
            end

          nil ->
            {:error, "EtherCAT interface #{inspect(interface)} does not exist"}
        end

      {:error, reason} ->
        {:error, "failed to inspect interface addresses: #{inspect(reason)}"}
    end
  end

  defp parse_ip!(ip_string, env_name) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip} ->
        ip

      {:error, _reason} ->
        raise ArgumentError, "#{env_name}=#{inspect(ip_string)} is not a valid IP address"
    end
  end

  defp env_interface(env_var, missing_message) do
    case System.get_env(env_var) do
      nil ->
        {:error, missing_message}

      "" ->
        {:error, missing_message}

      interface ->
        if File.exists?("/sys/class/net/#{interface}") do
          {:ok, interface}
        else
          {:error, "EtherCAT interface #{inspect(interface)} does not exist"}
        end
    end
  end
end
