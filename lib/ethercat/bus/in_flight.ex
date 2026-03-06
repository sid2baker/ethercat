defmodule EtherCAT.Bus.InFlight do
  @moduledoc false

  @type awaiting_t :: {:gen_statem.from(), [byte()]}

  @type t :: %__MODULE__{
          awaiting: [awaiting_t],
          tx_at: integer(),
          payload_size: non_neg_integer(),
          datagram_count: pos_integer()
        }

  defstruct [:awaiting, :tx_at, :payload_size, :datagram_count]
end
