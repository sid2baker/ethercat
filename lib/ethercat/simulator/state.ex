defmodule EtherCAT.Simulator.State do
  @moduledoc false

  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Runtime.{Faults, Subscriptions, Topology}
  alias EtherCAT.Simulator.Slave.Runtime.Device

  @enforce_keys [:slaves, :faults, :connections, :subscriptions, :scheduled_faults, :topology]
  defstruct [
    :backend,
    :slaves,
    :faults,
    :connections,
    :subscriptions,
    :scheduled_faults,
    :topology
  ]

  @type t :: %__MODULE__{
          backend: EtherCAT.Backend.t() | nil,
          slaves: [Device.t()],
          faults: Faults.t(),
          connections: [Simulator.connection()],
          subscriptions: Subscriptions.t(),
          scheduled_faults: [map()],
          topology: Topology.t()
        }

  @spec new([Device.t()], Topology.t(), EtherCAT.Backend.t() | nil) :: t()
  def new(slaves, topology, backend) when is_list(slaves) do
    %__MODULE__{
      backend: backend,
      slaves: slaves,
      faults: Faults.new(),
      connections: [],
      subscriptions: Subscriptions.new(),
      scheduled_faults: [],
      topology: topology
    }
  end
end
