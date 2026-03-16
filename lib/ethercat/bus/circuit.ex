defmodule EtherCAT.Bus.Circuit do
  @moduledoc """
  Behaviour for executing one EtherCAT exchange over one or more transports.

  A `Circuit` sits above `Bus.Transport` and below `EtherCAT.Bus`:

  - `Transport` owns socket/device I/O
  - `Circuit` owns one exchange across one or more ports
  - `Bus` owns scheduling, deadlines, batching, and caller replies

  `observe/3` is intentionally incremental. The `Exchange.pending` field
  carries the circuit-specific receive accumulator between mailbox messages
  until the circuit can emit a final `Bus.Observation`.
  """

  alias EtherCAT.Bus.Observation
  alias EtherCAT.Bus.Circuit.Exchange

  @type t :: struct()
  @callback open(keyword()) :: {:ok, t()} | {:error, term()}
  @callback begin_exchange(t(), Exchange.t()) ::
              {:ok, t(), Exchange.t()}
              | {:error, t(), Observation.t(), term()}

  @callback observe(t(), term(), Exchange.t()) ::
              {:ignore, t(), Exchange.t()}
              | {:continue, t(), Exchange.t()}
              | {:complete, t(), Observation.t()}

  @callback timeout(t(), Exchange.t()) ::
              {:continue, t(), Exchange.t(), pos_integer()}
              | {:complete, t(), Observation.t()}
  @callback drain(t()) :: t()
  @callback close(t()) :: t()
  @callback name(t()) :: String.t()
  @callback info(t()) :: map()
end
