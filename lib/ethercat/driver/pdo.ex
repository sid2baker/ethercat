defmodule EtherCAT.Driver.PDO do
  @moduledoc """
  One discovered PDO supplied to `c:EtherCAT.Driver.signal_model/2`.

  Direction is from the master's perspective. `bit_offset` is relative to its
  SyncManager image; `bit_size` is the PDO's complete size in bits. A signal's
  offset is relative to this PDO instead.
  """

  @enforce_keys [:index, :direction, :sm_index, :bit_size, :bit_offset]
  defstruct [:index, :direction, :sm_index, :bit_size, :bit_offset]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          direction: :input | :output,
          sm_index: non_neg_integer(),
          bit_size: non_neg_integer(),
          bit_offset: non_neg_integer()
        }
end
