defmodule EtherCAT.Simulator.Slave do
  @moduledoc """
  Device and signal-level API for simulated EtherCAT slaves.

  Use this module to hydrate simulated devices from real
  `EtherCAT.Slave.Driver` modules and to inspect or override named signal
  values on a running simulator.

  For drivers that opt in, `from_driver/2` can hydrate a simulated device from
  a real `EtherCAT.Slave.Driver` module via its optional
  `simulator_definition/1` callback.
  """

  alias EtherCAT.Simulator
  alias EtherCAT.Slave.Driver, as: SlaveDriver
  alias EtherCAT.Simulator.Slave.Definition

  @type driver :: module()
  @type device :: Definition.t()
  @type signal_ref :: {atom(), atom()}

  @spec from_driver(driver(), keyword()) :: device()
  def from_driver(driver, opts \\ []) when is_atom(driver) do
    config = Keyword.get(opts, :config, %{})
    name = Keyword.get(opts, :name)

    case SlaveDriver.simulator_definition(driver, config) do
      %Definition{} = definition ->
        maybe_override_name(definition, name)

      nil ->
        raise ArgumentError,
              "driver #{inspect(driver)} does not implement simulator_definition/1"
    end
  end

  @spec signals(device()) :: [atom()]
  def signals(%{signals: signals}) do
    Map.keys(signals)
  end

  @spec signals(atom()) :: {:ok, [atom()]} | {:error, :not_found}
  def signals(slave_name) when is_atom(slave_name) do
    Simulator.signals(slave_name)
  end

  @spec signal_definitions(device()) :: %{optional(atom()) => map()}
  def signal_definitions(%{signals: signals}), do: signals

  @spec signal_definitions(atom()) ::
          {:ok, %{optional(atom()) => map()}} | {:error, :not_found}
  def signal_definitions(slave_name) when is_atom(slave_name) do
    Simulator.signal_definitions(slave_name)
  end

  @spec get_value(atom(), atom()) ::
          {:ok, term()} | {:error, :not_found | :unknown_signal}
  def get_value(slave_name, signal_name)
      when is_atom(slave_name) and is_atom(signal_name) do
    Simulator.get_value(slave_name, signal_name)
  end

  @spec set_value(atom(), atom(), term()) ::
          :ok | {:error, :not_found | :unknown_signal | :invalid_value}
  def set_value(slave_name, signal_name, value)
      when is_atom(slave_name) and is_atom(signal_name) do
    Simulator.set_value(slave_name, signal_name, value)
  end

  @spec connect(signal_ref(), signal_ref()) ::
          :ok | {:error, :not_found | :unknown_signal | :invalid_value}
  def connect({source_slave, source_signal}, {target_slave, target_signal})
      when is_atom(source_slave) and is_atom(source_signal) and is_atom(target_slave) and
             is_atom(target_signal) do
    Simulator.connect({source_slave, source_signal}, {target_slave, target_signal})
  end

  @spec disconnect(signal_ref(), signal_ref()) :: :ok | {:error, :not_found}
  def disconnect({source_slave, source_signal}, {target_slave, target_signal})
      when is_atom(source_slave) and is_atom(source_signal) and is_atom(target_slave) and
             is_atom(target_signal) do
    Simulator.disconnect({source_slave, source_signal}, {target_slave, target_signal})
  end

  @spec connections() :: {:ok, [map()]} | {:error, :not_found | :timeout}
  def connections, do: Simulator.connections()

  @spec subscribe(atom()) :: :ok | {:error, :not_found}
  def subscribe(slave_name) when is_atom(slave_name) do
    Simulator.subscribe(slave_name, :all, self())
  end

  @spec subscribe(atom(), atom() | :all) :: :ok | {:error, :not_found}
  def subscribe(slave_name, signal_name)
      when is_atom(slave_name) and (is_atom(signal_name) or signal_name == :all) do
    Simulator.subscribe(slave_name, signal_name, self())
  end

  @spec subscribe(atom(), atom() | :all, pid()) :: :ok | {:error, :not_found}
  def subscribe(slave_name, signal_name, subscriber)
      when is_atom(slave_name) and (is_atom(signal_name) or signal_name == :all) and
             is_pid(subscriber) do
    Simulator.subscribe(slave_name, signal_name, subscriber)
  end

  @spec unsubscribe(atom()) :: :ok | {:error, :not_found}
  def unsubscribe(slave_name) when is_atom(slave_name) do
    Simulator.unsubscribe(slave_name, :all, self())
  end

  @spec unsubscribe(atom(), atom() | :all) :: :ok | {:error, :not_found}
  def unsubscribe(slave_name, signal_name)
      when is_atom(slave_name) and (is_atom(signal_name) or signal_name == :all) do
    Simulator.unsubscribe(slave_name, signal_name, self())
  end

  @spec unsubscribe(atom(), atom() | :all, pid()) :: :ok | {:error, :not_found}
  def unsubscribe(slave_name, signal_name, subscriber)
      when is_atom(slave_name) and (is_atom(signal_name) or signal_name == :all) and
             is_pid(subscriber) do
    Simulator.unsubscribe(slave_name, signal_name, subscriber)
  end

  defp maybe_override_name(definition, nil), do: definition
  defp maybe_override_name(definition, name) when is_atom(name), do: %{definition | name: name}
end
