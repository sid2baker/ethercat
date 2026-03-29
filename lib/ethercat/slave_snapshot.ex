defmodule EtherCAT.SlaveSnapshot do
  @moduledoc """
  Public driver-backed snapshot for one named slave.

  `EtherCAT.snapshot/1` returns this struct directly, and `EtherCAT.snapshot/0`
  aggregates these snapshots under one runtime-wide envelope.
  """

  alias EtherCAT.Endpoint

  @enforce_keys [:name, :driver, :al_state, :endpoints, :commands, :state, :faults]
  defstruct [
    :name,
    :driver,
    :al_state,
    :cycle,
    :device_type,
    endpoints: [],
    commands: [],
    state: %{},
    faults: [],
    updated_at_us: nil,
    driver_error: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          driver: module(),
          al_state: atom(),
          cycle: integer() | nil,
          device_type: atom() | nil,
          endpoints: [Endpoint.t()],
          commands: [atom()],
          state: %{optional(atom()) => term()},
          faults: [term()],
          updated_at_us: integer() | nil,
          driver_error: term() | nil
        }
end
