defmodule EtherCAT.Simulator.Runtime.Snapshot do
  @moduledoc false

  alias EtherCAT.Simulator.State
  alias EtherCAT.Simulator.Runtime.{Faults, Topology}
  alias EtherCAT.Simulator.Runtime.Slaves
  alias EtherCAT.Simulator.Slave.Runtime.Device
  alias EtherCAT.Simulator.Runtime.Subscriptions

  @type simulator_state :: State.t()

  @spec simulator(simulator_state()) :: map()
  def simulator(%State{
        slaves: slaves,
        faults: faults,
        connections: connections,
        subscriptions: subscriptions,
        scheduled_faults: scheduled_faults,
        topology: topology
      }) do
    faults_info = Faults.info(faults)
    scheduled_faults = scheduled_fault_info(scheduled_faults)

    %{
      slaves: Enum.map(slaves, &Device.info/1),
      connections: connections,
      subscriptions: Subscriptions.info(subscriptions),
      scheduled_faults: scheduled_faults,
      topology: topology
    }
    |> Map.merge(faults_info)
    |> Map.update!(:topology, &Topology.info/1)
  end

  @spec device(simulator_state(), atom()) :: {:ok, map()} | {:error, :not_found}
  def device(%State{slaves: slaves}, slave_name) do
    with {:ok, slave} <- Slaves.fetch(slaves, slave_name) do
      {:ok, Device.info(slave)}
    end
  end

  @spec signal(simulator_state(), atom(), atom()) ::
          {:ok, map()} | {:error, :not_found | :unknown_signal}
  def signal(%State{slaves: slaves}, slave_name, signal_name) do
    with {:ok, slave} <- Slaves.fetch(slaves, slave_name),
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

  defp scheduled_fault_info(scheduled_faults) do
    now_ms = System.monotonic_time(:millisecond)

    Enum.map(scheduled_faults, fn
      %{kind: :timer, due_at_ms: due_at_ms, fault: fault} ->
        %{
          fault: fault,
          due_in_ms: max(due_at_ms - now_ms, 0)
        }

      %{kind: :milestone, milestone: milestone, remaining: remaining, fault: fault} ->
        %{
          fault: fault,
          waiting_on: milestone,
          remaining: remaining
        }

      %{
        kind: :script_resume,
        remaining_exchange_steps: remaining_exchange_steps,
        steps: steps
      } ->
        %{
          fault: {:fault_script, steps},
          waiting_on: {:queued_exchange_steps, remaining_exchange_steps},
          remaining: remaining_exchange_steps
        }

      %{kind: :script_milestone, milestone: milestone, remaining: remaining, steps: steps} ->
        %{
          fault: {:fault_script, steps},
          waiting_on: milestone,
          remaining: remaining
        }
    end)
  end
end
