defmodule EtherCAT.Simulator.DriverAdapter do
  @moduledoc """
  Optional simulator-side companion for a real `EtherCAT.Driver`.

  The adapter returns authored simulator configuration as keyword options for
  `EtherCAT.Simulator.Slave.Definition.build/2`. It must include `:profile`.
  `EtherCAT.Simulator.Slave.from_driver/2` merges those options with the real
  driver's declared identity so simulator hydration stays aligned with the
  runtime-facing driver.
  """

  @type definition_options :: keyword()

  @callback definition_options(config :: map()) :: definition_options()

  @spec resolve(module(), module() | nil) :: module() | nil
  def resolve(driver, nil) when is_atom(driver) do
    candidate = Module.concat(driver, "Simulator")

    if Code.ensure_loaded?(candidate) and function_exported?(candidate, :definition_options, 1) do
      candidate
    else
      nil
    end
  end

  def resolve(_driver, simulator) when is_atom(simulator) do
    if Code.ensure_loaded?(simulator) and function_exported?(simulator, :definition_options, 1) do
      simulator
    else
      nil
    end
  end

  def resolve(_driver, _simulator), do: nil

  @spec definition_options(module(), map()) :: definition_options()
  def definition_options(adapter, config) when is_atom(adapter) and is_map(config) do
    apply(adapter, :definition_options, [config])
  end
end
