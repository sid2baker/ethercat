defmodule EtherCAT.Domain.Config do
  @moduledoc """
  Declarative configuration struct for a Domain.

  Fields:
    - `:id` (required) — atom identifying the domain; also used as the ETS table name
    - `:cycle_time_us` (required) — cycle time in microseconds; must be a whole-millisecond value (`>= 1_000`, divisible by `1_000`)
    - `:miss_threshold` — consecutive miss count before domain halts, default `1000`
    - `:logical_base` — LRW logical address base, default `0`
  """

  @enforce_keys [:id, :cycle_time_us]
  defstruct [
    :id,
    :cycle_time_us,
    miss_threshold: 1000,
    logical_base: 0
  ]
end
