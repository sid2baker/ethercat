defmodule EtherCAT.Domain.Config do
  @moduledoc """
  Declarative configuration struct for a Domain.

  Fields:
    - `:id` (required) — atom identifying the domain; also used as the ETS table name
    - `:period_ms` (required) — cycle period in milliseconds
    - `:miss_threshold` — consecutive miss count before domain halts, default `1000`
    - `:logical_base` — LRW logical address base, default `0`
  """

  @enforce_keys [:id, :period_ms]
  defstruct [
    :id,
    :period_ms,
    miss_threshold: 1000,
    logical_base: 0
  ]
end
