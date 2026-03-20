defmodule EtherCAT.SlaveSnapshot do
  @moduledoc """
  Public driver-backed snapshot for one named slave.

  `EtherCAT.snapshot/1` returns this struct directly, and `EtherCAT.snapshot/0`
  aggregates these snapshots under one runtime-wide envelope.
  """

  @enforce_keys [:name, :al_state, :capabilities, :state, :faults]
  defstruct [
    :name,
    :al_state,
    :cycle,
    :device_type,
    capabilities: [],
    state: %{},
    faults: [],
    updated_at_us: nil,
    driver_error: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          al_state: atom(),
          cycle: integer() | nil,
          device_type: atom() | nil,
          capabilities: [atom()],
          state: %{optional(atom()) => term()},
          faults: [term()],
          updated_at_us: integer() | nil,
          driver_error: term() | nil
        }
end
