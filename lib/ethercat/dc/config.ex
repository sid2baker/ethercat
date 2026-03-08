defmodule EtherCAT.DC.Config do
  @moduledoc """
  Declarative configuration for master-wide Distributed Clocks infrastructure.

  Fields:
    - `:cycle_ns` — global DC cycle in nanoseconds, default `1_000_000`; must be a whole-millisecond value (`>= 1_000_000`, divisible by `1_000_000`)
    - `:await_lock?` — gate activation on DC lock detection, default `false`
    - `:lock_policy` — runtime reaction to DC lock loss: `:advisory | :recovering | :fatal`, default `:advisory`
    - `:lock_threshold_ns` — acceptable absolute sync-diff threshold, default `100`
    - `:lock_timeout_ms` — timeout while waiting for lock, default `5_000`
    - `:warmup_cycles` — optional pre-compensation cycle count, default `0`

  Disable DC entirely by passing `dc: nil` to `EtherCAT.start/1`.
  """

  @type t :: %__MODULE__{
          cycle_ns: pos_integer(),
          await_lock?: boolean(),
          lock_policy: :advisory | :recovering | :fatal,
          lock_threshold_ns: pos_integer(),
          lock_timeout_ms: pos_integer(),
          warmup_cycles: non_neg_integer()
        }

  defstruct cycle_ns: 1_000_000,
            await_lock?: false,
            lock_policy: :advisory,
            lock_threshold_ns: 100,
            lock_timeout_ms: 5_000,
            warmup_cycles: 0
end
