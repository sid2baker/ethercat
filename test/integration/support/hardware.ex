defmodule EtherCAT.IntegrationSupport.Hardware do
  @moduledoc false

  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.IntegrationSupport.Drivers.{EK1100, EL1809, EL2809, EL3202}
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @spec interface() :: {:ok, binary()} | {:error, binary()}
  def interface do
    case System.get_env("ETHERCAT_INTERFACE") do
      nil ->
        {:error, "set ETHERCAT_INTERFACE to run hardware integration tests"}

      "" ->
        {:error, "set ETHERCAT_INTERFACE to run hardware integration tests"}

      interface ->
        if File.exists?("/sys/class/net/#{interface}") do
          {:ok, interface}
        else
          {:error, "EtherCAT interface #{inspect(interface)} does not exist"}
        end
    end
  end

  @spec interface!() :: binary()
  def interface! do
    case interface() do
      {:ok, interface} -> interface
      {:error, reason} -> raise ArgumentError, reason
    end
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
    coupler_opts = Keyword.get(opts, :coupler, [])
    inputs_opts = Keyword.get(opts, :inputs, [])
    outputs_opts = Keyword.get(opts, :outputs, [])
    rtd_opts = Keyword.get(opts, :rtd, [])

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
end
