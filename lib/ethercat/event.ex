defmodule EtherCAT.Event do
  @moduledoc """
  Public driver-backed slave event envelope emitted by `EtherCAT.subscribe/2`.

  Events are scoped to one named slave. Signal-state changes still populate
  `:signal` and `:value`, while command lifecycle and other driver/runtime
  notices are carried as `kind: :event` with the original payload in `:data`.
  """

  @type kind ::
          :signal_changed
          | :fault_raised
          | :fault_cleared
          | :event

  @type signal_ref :: {slave :: atom(), signal_name :: atom()}

  @enforce_keys [:kind, :updated_at_us]
  defstruct [
    :kind,
    :signal,
    :slave,
    :cycle,
    :updated_at_us,
    :value,
    data: nil
  ]

  @type t :: %__MODULE__{
          kind: kind(),
          signal: signal_ref() | nil,
          slave: atom() | nil,
          cycle: integer() | nil,
          updated_at_us: integer(),
          value: term() | nil,
          data: term() | nil
        }

  @spec signal_changed(atom(), atom(), term(), integer() | nil, integer()) :: t()
  def signal_changed(slave, signal_name, value, cycle, updated_at_us) do
    %__MODULE__{
      kind: :signal_changed,
      signal: {slave, signal_name},
      slave: slave,
      value: value,
      cycle: cycle,
      updated_at_us: updated_at_us
    }
  end

  @spec fault_raised(atom(), term(), map(), integer() | nil, integer()) :: t()
  def fault_raised(slave, fault, meta, cycle, updated_at_us) when is_map(meta) do
    %__MODULE__{
      kind: :fault_raised,
      slave: slave,
      data: %{fault: fault, meta: meta},
      cycle: cycle,
      updated_at_us: updated_at_us
    }
  end

  @spec fault_cleared(atom(), term(), map(), integer() | nil, integer()) :: t()
  def fault_cleared(slave, fault, meta, cycle, updated_at_us) when is_map(meta) do
    %__MODULE__{
      kind: :fault_cleared,
      slave: slave,
      data: %{fault: fault, meta: meta},
      cycle: cycle,
      updated_at_us: updated_at_us
    }
  end

  @spec internal(atom() | nil, term(), integer() | nil, integer()) :: t()
  def internal(slave, data, cycle, updated_at_us) do
    %__MODULE__{
      kind: :event,
      slave: slave,
      data: data,
      cycle: cycle,
      updated_at_us: updated_at_us
    }
  end
end
