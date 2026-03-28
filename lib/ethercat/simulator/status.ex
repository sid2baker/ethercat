defmodule EtherCAT.Simulator.Status do
  @moduledoc """
  Stable machine-readable simulator runtime status.
  """

  alias EtherCAT.Backend

  @type lifecycle :: :stopped | :running

  @type t :: %__MODULE__{
          lifecycle: lifecycle(),
          backend: Backend.t() | nil,
          topology: map() | nil,
          devices: [map()],
          injected_faults: map(),
          scheduled_faults: [map()],
          connections: [map()],
          subscriptions: map()
        }

  defstruct lifecycle: :stopped,
            backend: nil,
            topology: nil,
            devices: [],
            injected_faults: %{},
            scheduled_faults: [],
            connections: [],
            subscriptions: %{}

  @spec stopped() :: t()
  def stopped, do: %__MODULE__{}
end
