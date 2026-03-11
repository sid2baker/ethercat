defmodule EtherCAT.Simulator.State do
  @moduledoc false

  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Runtime.{Faults, Subscriptions}
  alias EtherCAT.Simulator.Slave.Runtime.Device

  @enforce_keys [:slaves, :faults, :connections, :subscriptions]
  defstruct [:slaves, :faults, :connections, :subscriptions]

  @type t :: %__MODULE__{
          slaves: [Device.t()],
          faults: Faults.t(),
          connections: [Simulator.connection()],
          subscriptions: Subscriptions.t()
        }

  @spec new([Device.t()]) :: t()
  def new(slaves) when is_list(slaves) do
    %__MODULE__{
      slaves: slaves,
      faults: Faults.new(),
      connections: [],
      subscriptions: Subscriptions.new()
    }
  end
end
