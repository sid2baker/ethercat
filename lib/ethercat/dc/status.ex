defmodule EtherCAT.DC.Status do
  @moduledoc """
  Runtime status snapshot for Distributed Clocks.

  `lock_state` values:
    - `:disabled` — DC not configured for this session
    - `:inactive` — DC configured but not currently active
    - `:unavailable` — DC active, but no monitorable sync-diff stations are available
    - `:locking` — DC lock detection is active and still converging
    - `:locked` — DC lock detection reports convergence

  `monitor_failures` counts consecutive runtime failures inside the
  `EtherCAT.DC` worker. That includes diagnostic decode failures and
  transport/runtime tick failures before the next successful DC frame.

  `await_lock?` and `lock_policy` expose the configured DC contract:

  - `await_lock?` applies during activation
  - `lock_policy` applies after activation if lock is later lost
  """

  @type lock_state :: :disabled | :inactive | :unavailable | :locking | :locked
  @type lock_policy :: :advisory | :recovering | :fatal

  @type t :: %__MODULE__{
          configured?: boolean(),
          active?: boolean(),
          cycle_ns: pos_integer() | nil,
          await_lock?: boolean(),
          lock_policy: lock_policy() | nil,
          reference_station: non_neg_integer() | nil,
          reference_clock: atom() | nil,
          lock_state: lock_state(),
          max_sync_diff_ns: non_neg_integer() | nil,
          last_sync_check_at_ms: integer() | nil,
          monitor_failures: non_neg_integer()
        }

  defstruct configured?: false,
            active?: false,
            cycle_ns: nil,
            await_lock?: false,
            lock_policy: nil,
            reference_station: nil,
            reference_clock: nil,
            lock_state: :inactive,
            max_sync_diff_ns: nil,
            last_sync_check_at_ms: nil,
            monitor_failures: 0
end
