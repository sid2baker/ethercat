defmodule EtherCAT.Bus.Result do
  @moduledoc """
  Result of a single EtherCAT datagram round-trip.

  Results are returned in the same order as commands were added
  to the transaction.

  ## Fields

    * `data` — response payload (binary)
    * `wkc` — working counter (raw, caller interprets)
    * `circular` — `true` if the frame circulated (ring break indicator, spec §3.5)
    * `irq` — AL event request bitmask (2-byte little-endian binary),
      ORed across all slaves the datagram passed through (spec §12)

  ## Example

      {:ok, [%Result{data: <<status::16-little>>, wkc: 1}]} =
        Bus.transaction(bus, &Transaction.fprd(&1, 0x1001, Registers.al_status()))
  """

  @type t :: %__MODULE__{
          data: binary(),
          wkc: non_neg_integer(),
          circular: boolean(),
          irq: <<_::16>>
        }

  defstruct [:data, wkc: 0, circular: false, irq: <<0, 0>>]
end
