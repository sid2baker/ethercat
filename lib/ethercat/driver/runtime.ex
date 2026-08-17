defmodule EtherCAT.Driver.Runtime do
  @moduledoc false

  alias EtherCAT.Driver
  alias EtherCAT.SlaveDescription
  alias EtherCAT.Slave.ProcessData.Signal

  @spec signal_model(module(), Driver.config()) ::
          [{Driver.signal_name(), non_neg_integer() | Signal.t()}]
  def signal_model(driver, config) when is_atom(driver) and is_map(config) do
    signal_model(driver, config, [])
  end

  @spec signal_model(module(), Driver.config(), [map()]) ::
          [{Driver.signal_name(), non_neg_integer() | Signal.t()}]
  def signal_model(driver, config, sii_pdo_configs)
      when is_atom(driver) and is_map(config) and is_list(sii_pdo_configs) do
    apply(driver, :signal_model, [config, sii_pdo_configs])
  end

  @spec describe(module(), Driver.config()) :: Driver.description()
  def describe(driver, config) when is_atom(driver) and is_map(config) do
    SlaveDescription.native_description(driver, config)
  end

  @spec device_type(module(), Driver.config()) :: atom() | nil
  def device_type(driver, config) when is_atom(driver) and is_map(config) do
    describe(driver, config)
    |> Map.get(:device_type)
  end

  @spec endpoints(module(), Driver.config()) :: [EtherCAT.Endpoint.t()]
  def endpoints(driver, config) when is_atom(driver) and is_map(config) do
    describe(driver, config)
    |> Map.get(:endpoints, [])
  end
end
