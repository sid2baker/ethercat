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

  @spec commands(module(), Driver.config()) :: [atom()]
  def commands(driver, config) when is_atom(driver) and is_map(config) do
    describe(driver, config)
    |> Map.get(:commands, [])
  end

  @spec capabilities(module(), Driver.config()) :: [atom()]
  def capabilities(driver, config), do: commands(driver, config)

  @spec endpoints(module(), Driver.config()) :: [EtherCAT.Endpoint.t()]
  def endpoints(driver, config) when is_atom(driver) and is_map(config) do
    describe(driver, config)
    |> Map.get(:endpoints, [])
  end

  @spec init_state(module(), Driver.config()) :: {:ok, term()} | {:error, term()}
  def init_state(driver, config) when is_atom(driver) and is_map(config) do
    if exported?(driver, :init, 1) do
      apply(driver, :init, [config])
    else
      {:ok, %{}}
    end
  end

  @spec project_state(
          module(),
          Driver.decoded_inputs(),
          Driver.projected_state() | nil,
          term(),
          Driver.config()
        ) ::
          {:ok, Driver.projected_state(), term(), [Driver.notice()], [term()]}
          | {:error, term()}
  def project_state(driver, decoded_inputs, prev_state, driver_state, config)
      when is_atom(driver) and is_map(decoded_inputs) and
             (is_map(prev_state) or is_nil(prev_state)) and
             is_map(config) do
    apply(driver, :project_state, [decoded_inputs, prev_state, driver_state, config])
  end

  @spec command(
          module(),
          Driver.command_request(),
          Driver.projected_state(),
          term(),
          Driver.config()
        ) ::
          {:ok, [Driver.output_intent()], term(), [Driver.notice()]} | {:error, term()}
  def command(driver, command, projected_state, driver_state, config)
      when is_atom(driver) and is_map(command) and is_map(projected_state) and is_map(config) do
    apply(driver, :command, [command, projected_state, driver_state, config])
  end

  defp exported?(module, function_name, arity)
       when is_atom(module) and is_atom(function_name) and is_integer(arity) and arity >= 0 do
    Code.ensure_loaded?(module) and function_exported?(module, function_name, arity)
  end
end
