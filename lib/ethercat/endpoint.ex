defmodule EtherCAT.Endpoint do
  @moduledoc """
  Public description of one driver-backed endpoint on a configured slave.

  `signal` is the driver's native backing signal name. `name` is the effective
  public endpoint name after any slave-local aliasing is applied.
  """

  @type direction :: :input | :output
  @type endpoint_type :: atom()

  @enforce_keys [:signal, :name, :direction, :type]
  defstruct [:signal, :name, :direction, :type, :label, :description]

  @type t :: %__MODULE__{
          signal: atom(),
          name: atom(),
          direction: direction(),
          type: endpoint_type(),
          label: String.t() | nil,
          description: String.t() | nil
        }
end
