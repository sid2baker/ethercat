defmodule EtherCAT.Simulator.Runtime.Faults do
  @moduledoc false

  @command_names [
    :aprd,
    :apwr,
    :aprw,
    :fprd,
    :fpwr,
    :fprw,
    :brd,
    :bwr,
    :brw,
    :lrd,
    :lwr,
    :lrw,
    :armw,
    :frmw
  ]

  @type sticky_fault ::
          :drop_responses
          | {:wkc_offset, integer()}
          | {:command_wkc_offset, command_name(), integer()}
          | {:logical_wkc_offset, atom(), integer()}
          | {:disconnect, atom()}

  @type command_name ::
          :aprd
          | :apwr
          | :aprw
          | :fprd
          | :fpwr
          | :fprw
          | :brd
          | :bwr
          | :brw
          | :lrd
          | :lwr
          | :lrw
          | :armw
          | :frmw

  @type exchange_fault :: sticky_fault()

  @type planned_fault ::
          {:next_exchange, exchange_fault()}
          | {:next_exchanges, pos_integer(), exchange_fault()}
          | {:fault_script, [exchange_fault(), ...]}

  @type fault :: sticky_fault() | planned_fault()

  @type pending_fault_source :: :manual | {:script, pos_integer()}

  @type pending_fault_entry :: %{
          fault: exchange_fault(),
          source: pending_fault_source()
        }

  @type t :: %__MODULE__{
          drop_responses?: boolean(),
          wkc_offset: integer(),
          command_wkc_offsets: %{optional(command_name()) => integer()},
          logical_wkc_offsets: %{optional(atom()) => integer()},
          disconnected: MapSet.t(atom()),
          pending_faults: [pending_fault_entry()]
        }

  @enforce_keys [
    :drop_responses?,
    :wkc_offset,
    :command_wkc_offsets,
    :logical_wkc_offsets,
    :disconnected,
    :pending_faults
  ]
  defstruct [
    :drop_responses?,
    :wkc_offset,
    :command_wkc_offsets,
    :logical_wkc_offsets,
    :disconnected,
    :pending_faults
  ]

  @spec new() :: t()
  def new do
    %__MODULE__{
      drop_responses?: false,
      wkc_offset: 0,
      command_wkc_offsets: %{},
      logical_wkc_offsets: %{},
      disconnected: MapSet.new(),
      pending_faults: []
    }
  end

  @spec info(t()) :: map()
  def info(%__MODULE__{} = faults) do
    %{
      drop_responses?: faults.drop_responses?,
      wkc_offset: faults.wkc_offset,
      command_wkc_offsets: faults.command_wkc_offsets,
      logical_wkc_offsets: faults.logical_wkc_offsets,
      disconnected: MapSet.to_list(faults.disconnected),
      next_fault: next_fault_info(faults.pending_faults),
      pending_faults: Enum.map(faults.pending_faults, & &1.fault)
    }
  end

  @spec inject(t(), sticky_fault()) :: t()
  def inject(%__MODULE__{} = faults, :drop_responses) do
    %{faults | drop_responses?: true}
  end

  def inject(%__MODULE__{} = faults, {:wkc_offset, delta}) when is_integer(delta) do
    %{faults | wkc_offset: delta}
  end

  def inject(%__MODULE__{} = faults, {:command_wkc_offset, command_name, delta})
      when command_name in @command_names and is_integer(delta) do
    %{faults | command_wkc_offsets: Map.put(faults.command_wkc_offsets, command_name, delta)}
  end

  def inject(%__MODULE__{} = faults, {:logical_wkc_offset, slave_name, delta})
      when is_atom(slave_name) and is_integer(delta) do
    %{faults | logical_wkc_offsets: Map.put(faults.logical_wkc_offsets, slave_name, delta)}
  end

  def inject(%__MODULE__{} = faults, {:disconnect, slave_name}) when is_atom(slave_name) do
    %{faults | disconnected: MapSet.put(faults.disconnected, slave_name)}
  end

  @spec enqueue(t(), planned_fault()) :: {:ok, t()} | :error
  def enqueue(%__MODULE__{} = faults, {:next_exchange, fault}) do
    if valid_exchange_fault?(fault) do
      {:ok, enqueue_entry(faults, %{fault: fault, source: :manual})}
    else
      :error
    end
  end

  def enqueue(%__MODULE__{} = faults, {:next_exchanges, count, fault})
      when is_integer(count) and count > 0 do
    if valid_exchange_fault?(fault) do
      entries = List.duplicate(%{fault: fault, source: :manual}, count)
      {:ok, %{faults | pending_faults: faults.pending_faults ++ entries}}
    else
      :error
    end
  end

  def enqueue(%__MODULE__{} = faults, {:fault_script, planned_faults})
      when is_list(planned_faults) do
    if planned_faults != [] and Enum.all?(planned_faults, &valid_exchange_fault?/1) do
      entries = Enum.map(planned_faults, &%{fault: &1, source: :manual})
      {:ok, %{faults | pending_faults: faults.pending_faults ++ entries}}
    else
      :error
    end
  end

  def enqueue(%__MODULE__{}, _planned_fault), do: :error

  @spec enqueue_script_steps(t(), pos_integer(), [exchange_fault(), ...]) :: {:ok, t()} | :error
  def enqueue_script_steps(%__MODULE__{} = faults, script_id, planned_faults)
      when is_integer(script_id) and script_id > 0 and is_list(planned_faults) do
    if planned_faults != [] and Enum.all?(planned_faults, &valid_exchange_fault?/1) do
      entries = Enum.map(planned_faults, &%{fault: &1, source: {:script, script_id}})
      {:ok, %{faults | pending_faults: faults.pending_faults ++ entries}}
    else
      :error
    end
  end

  @spec pop_pending(t()) :: {pending_fault_entry() | nil, t()}
  def pop_pending(%__MODULE__{pending_faults: []} = faults), do: {nil, faults}

  def pop_pending(%__MODULE__{pending_faults: [entry | rest]} = faults),
    do: {entry, %{faults | pending_faults: rest}}

  @spec apply_pending(t(), pending_fault_entry() | exchange_fault() | nil) :: t()
  def apply_pending(%__MODULE__{} = faults, nil), do: faults

  def apply_pending(%__MODULE__{} = faults, %{fault: fault}), do: apply_pending(faults, fault)

  def apply_pending(%__MODULE__{} = faults, :drop_responses),
    do: %{faults | drop_responses?: true}

  def apply_pending(%__MODULE__{} = faults, {:wkc_offset, delta}) when is_integer(delta),
    do: %{faults | wkc_offset: delta}

  def apply_pending(%__MODULE__{} = faults, {:command_wkc_offset, command_name, delta})
      when command_name in @command_names and is_integer(delta) do
    %{faults | command_wkc_offsets: Map.put(faults.command_wkc_offsets, command_name, delta)}
  end

  def apply_pending(%__MODULE__{} = faults, {:logical_wkc_offset, slave_name, delta})
      when is_atom(slave_name) and is_integer(delta) do
    %{faults | logical_wkc_offsets: Map.put(faults.logical_wkc_offsets, slave_name, delta)}
  end

  def apply_pending(%__MODULE__{} = faults, {:disconnect, slave_name}) when is_atom(slave_name) do
    %{faults | disconnected: MapSet.put(faults.disconnected, slave_name)}
  end

  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = faults) do
    %{
      faults
      | drop_responses?: false,
        wkc_offset: 0,
        command_wkc_offsets: %{},
        logical_wkc_offsets: %{},
        disconnected: MapSet.new(),
        pending_faults: []
    }
  end

  defp valid_exchange_fault?(:drop_responses), do: true
  defp valid_exchange_fault?({:wkc_offset, delta}) when is_integer(delta), do: true

  defp valid_exchange_fault?({:command_wkc_offset, command_name, delta})
       when command_name in @command_names and is_integer(delta),
       do: true

  defp valid_exchange_fault?({:logical_wkc_offset, slave_name, delta})
       when is_atom(slave_name) and is_integer(delta),
       do: true

  defp valid_exchange_fault?({:disconnect, slave_name}) when is_atom(slave_name), do: true
  defp valid_exchange_fault?(_fault), do: false

  defp next_fault_info([]), do: nil
  defp next_fault_info([%{fault: fault} | _rest]), do: {:next_exchange, fault}

  defp enqueue_entry(%__MODULE__{} = faults, entry) do
    %{faults | pending_faults: faults.pending_faults ++ [entry]}
  end
end
