defmodule EtherCAT.Endpoint do
  @moduledoc """
  Public description of one driver-backed endpoint on a configured slave.
  """

  @type direction :: :input | :output
  @type endpoint_type :: atom()

  @enforce_keys [:signal, :direction, :type]
  defstruct [:signal, :direction, :type, :label, :description]

  @type t :: %__MODULE__{
          signal: atom(),
          direction: direction(),
          type: endpoint_type(),
          label: String.t() | nil,
          description: String.t() | nil
        }
end
