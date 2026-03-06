defmodule EtherCAT.Slave.Sync.Config do
  @moduledoc """
  Declarative per-slave sync and latch configuration.

  This models user-facing sync intent. Master-wide Distributed Clocks still live
  under `EtherCAT.DC.Config`; this struct only describes how one slave should
  use SYNC0/SYNC1 and which latch edges should be surfaced by name.
  """

  @type mode :: :free_run | :sync0 | :sync1 | nil
  @type sync0 :: %{pulse_ns: pos_integer(), shift_ns: integer()}
  @type sync1 :: %{offset_ns: non_neg_integer()}
  @type latch_ref :: {0 | 1, :pos | :neg}

  @type t :: %__MODULE__{
          mode: mode(),
          sync0: sync0() | nil,
          sync1: sync1() | nil,
          latches: %{optional(atom()) => latch_ref()}
        }

  defstruct mode: nil,
            sync0: nil,
            sync1: nil,
            latches: %{}
end
