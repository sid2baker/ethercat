defmodule EtherCAT.Simulator.Runtime.Snapshot do
  @moduledoc false

  alias EtherCAT.Simulator.State
  alias EtherCAT.Simulator.Runtime.Faults
  alias EtherCAT.Simulator.Slave.Runtime.Device
  alias EtherCAT.Simulator.Runtime.Subscriptions

  @type simulator_state :: State.t()

  @spec simulator(simulator_state()) :: map()
  def simulator(%State{
        slaves: slaves,
        faults: faults,
        connections: connections,
        subscriptions: subscriptions
      }) do
    faults_info = Faults.info(faults)

    %{
      slaves: Enum.map(slaves, &Device.info/1),
      connections: connections,
      subscriptions: Subscriptions.info(subscriptions)
    }
    |> Map.merge(faults_info)
  end

  @spec device(simulator_state(), atom()) :: {:ok, map()} | {:error, :not_found}
  def device(%State{slaves: slaves}, slave_name) do
    with {:ok, slave} <- fetch_slave(slaves, slave_name) do
      {:ok, Device.info(slave)}
    end
  end

  @spec signal(simulator_state(), atom(), atom()) ::
          {:ok, map()} | {:error, :not_found | :unknown_signal}
  def signal(%State{slaves: slaves}, slave_name, signal_name) do
    with {:ok, slave} <- fetch_slave(slaves, slave_name),
         {:ok, definition} <- Device.signal_definition(slave, signal_name),
         {:ok, value} <- Device.get_value(slave, signal_name) do
      {:ok,
       %{
         slave: slave_name,
         signal: signal_name,
         definition: definition,
         value: value
       }}
    end
  end

  @spec connections(simulator_state()) :: [map()]
  def connections(%State{connections: connections}), do: connections

  defp fetch_slave(slaves, slave_name) do
    case Enum.find(slaves, &(&1.name == slave_name)) do
      nil -> {:error, :not_found}
      slave -> {:ok, slave}
    end
  end
end
