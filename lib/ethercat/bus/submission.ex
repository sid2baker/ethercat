defmodule EtherCAT.Bus.Submission do
  @moduledoc false

  alias EtherCAT.Bus.Transaction

  @type t :: %__MODULE__{
          from: :gen_statem.from(),
          tx: Transaction.t(),
          deadline_us: pos_integer() | nil,
          enqueued_at_us: integer()
        }

  defstruct [:from, :tx, :deadline_us, :enqueued_at_us]
end
