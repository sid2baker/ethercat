defmodule EtherCAT.Domain.Config do
  @moduledoc """
  Declarative configuration struct for a Domain.

  Fields:
    - `:id` (required) — atom identifying the domain; also used as the ETS table name
    - `:cycle_time_us` (required) — cycle time in microseconds; must be a whole-millisecond value (`>= 1_000`, divisible by `1_000`)
    - `:miss_threshold` — consecutive miss count before domain halts, default `1000`
    - `:recovery_threshold` — consecutive unhealthy cycles before the domain
      tells the master that runtime recovery is required, default `3`

  The high-level master API owns logical address allocation. If you use
  `EtherCAT.start/1`, domains are declared by intent (`id`, cycle time, miss
  threshold) and the master assigns non-overlapping logical windows before
  slaves program their FMMUs.

  If you bypass the master and start a domain directly through the low-level
  runtime API, that path still accepts an explicit `:logical_base` option.
  """

  @type t :: %__MODULE__{
          id: atom(),
          cycle_time_us: pos_integer(),
          miss_threshold: pos_integer(),
          recovery_threshold: pos_integer()
        }

  @enforce_keys [:id, :cycle_time_us]
  defstruct [
    :id,
    :cycle_time_us,
    miss_threshold: 1000,
    recovery_threshold: 3
  ]
end
