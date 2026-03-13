defmodule EtherCAT.Simulator.State do
  @moduledoc false

  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Runtime.{Faults, Subscriptions, Topology}
  alias EtherCAT.Simulator.Slave.Runtime.Device

  @enforce_keys [:slaves, :faults, :connections, :subscriptions, :scheduled_faults, :topology]
  defstruct [:slaves, :faults, :connections, :subscriptions, :scheduled_faults, :topology]

  @type t :: %__MODULE__{
          slaves: [Device.t()],
          faults: Faults.t(),
          connections: [Simulator.connection()],
          subscriptions: Subscriptions.t(),
          scheduled_faults: [map()],
          topology: Topology.t()
        }

  @spec new([Device.t()], Topology.t()) :: t()
  def new(slaves, topology) when is_list(slaves) do
    %__MODULE__{
      slaves: slaves,
      faults: Faults.new(),
      connections: [],
      subscriptions: Subscriptions.new(),
      scheduled_faults: [],
      topology: topology
    }
  end
end
