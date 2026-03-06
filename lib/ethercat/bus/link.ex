defmodule EtherCAT.Bus.Link do
  @moduledoc """
  Behaviour for bus link adapters.

  A link adapter owns wire/link mechanics for one bus topology, while
  `EtherCAT.Bus` owns scheduling, batching, timeouts, and reply routing.
  """

  @type t :: struct()

  @callback open(keyword()) :: {:ok, t()} | {:error, term()}
  @callback send(t(), binary()) :: {:ok, t()} | {:error, t(), term()}

  @callback match(t(), term()) ::
              {:ignore, t()}
              | {:pending, t()}
              | {:ok, t(), binary(), integer() | nil}

  @callback timeout(t()) :: {:error, t(), :timeout} | {:ok, t(), binary(), integer() | nil}
  @callback rearm(t()) :: t()
  @callback clear_awaiting(t()) :: t()
  @callback drain(t()) :: t()
  @callback close(t()) :: t()
  @callback carrier(t(), String.t(), boolean()) :: {:ok, t()} | {:down, t(), term()}
  @callback reconnect(t()) :: t()
  @callback usable?(t()) :: boolean()
  @callback needs_reconnect?(t()) :: boolean()
  @callback name(t()) :: String.t()
  @callback interfaces(t()) :: [String.t()]
end
