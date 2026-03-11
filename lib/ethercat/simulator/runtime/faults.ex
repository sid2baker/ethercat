defmodule EtherCAT.Simulator.Runtime.Faults do
  @moduledoc false

  @type sticky_fault ::
          :drop_responses
          | {:wkc_offset, integer()}
          | {:disconnect, atom()}

  @type exchange_fault :: sticky_fault()

  @type planned_fault ::
          {:next_exchange, exchange_fault()}
          | {:next_exchanges, pos_integer(), exchange_fault()}
          | {:exchange_script, [exchange_fault(), ...]}

  @type fault :: sticky_fault() | planned_fault()

  @type t :: %__MODULE__{
          drop_responses?: boolean(),
          wkc_offset: integer(),
          disconnected: MapSet.t(atom()),
          pending_faults: [exchange_fault()]
        }

  @enforce_keys [:drop_responses?, :wkc_offset, :disconnected, :pending_faults]
  defstruct [:drop_responses?, :wkc_offset, :disconnected, :pending_faults]

  @spec new() :: t()
  def new do
    %__MODULE__{
      drop_responses?: false,
      wkc_offset: 0,
      disconnected: MapSet.new(),
      pending_faults: []
    }
  end

  @spec info(t()) :: map()
  def info(%__MODULE__{} = faults) do
    %{
      drop_responses?: faults.drop_responses?,
      wkc_offset: faults.wkc_offset,
      disconnected: MapSet.to_list(faults.disconnected),
      next_fault: next_fault_info(faults.pending_faults),
      pending_faults: faults.pending_faults
    }
  end

  @spec inject(t(), sticky_fault()) :: t()
  def inject(%__MODULE__{} = faults, :drop_responses) do
    %{faults | drop_responses?: true}
  end

  def inject(%__MODULE__{} = faults, {:wkc_offset, delta}) when is_integer(delta) do
    %{faults | wkc_offset: delta}
  end

  def inject(%__MODULE__{} = faults, {:disconnect, slave_name}) when is_atom(slave_name) do
    %{faults | disconnected: MapSet.put(faults.disconnected, slave_name)}
  end

  @spec enqueue(t(), planned_fault()) :: {:ok, t()} | :error
  def enqueue(%__MODULE__{} = faults, {:next_exchange, fault}) do
    if valid_exchange_fault?(fault) do
      {:ok, %{faults | pending_faults: faults.pending_faults ++ [fault]}}
    else
      :error
    end
  end

  def enqueue(%__MODULE__{} = faults, {:next_exchanges, count, fault})
      when is_integer(count) and count > 0 do
    if valid_exchange_fault?(fault) do
      {:ok, %{faults | pending_faults: faults.pending_faults ++ List.duplicate(fault, count)}}
    else
      :error
    end
  end

  def enqueue(%__MODULE__{} = faults, {:exchange_script, planned_faults})
      when is_list(planned_faults) do
    if planned_faults != [] and Enum.all?(planned_faults, &valid_exchange_fault?/1) do
      {:ok, %{faults | pending_faults: faults.pending_faults ++ planned_faults}}
    else
      :error
    end
  end

  def enqueue(%__MODULE__{}, _planned_fault), do: :error

  @spec pop_pending(t()) :: {exchange_fault() | nil, t()}
  def pop_pending(%__MODULE__{pending_faults: []} = faults), do: {nil, faults}

  def pop_pending(%__MODULE__{pending_faults: [fault | rest]} = faults),
    do: {fault, %{faults | pending_faults: rest}}

  @spec apply_pending(t(), exchange_fault() | nil) :: t()
  def apply_pending(%__MODULE__{} = faults, nil), do: faults

  def apply_pending(%__MODULE__{} = faults, :drop_responses),
    do: %{faults | drop_responses?: true}

  def apply_pending(%__MODULE__{} = faults, {:wkc_offset, delta}) when is_integer(delta),
    do: %{faults | wkc_offset: delta}

  def apply_pending(%__MODULE__{} = faults, {:disconnect, slave_name}) when is_atom(slave_name) do
    %{faults | disconnected: MapSet.put(faults.disconnected, slave_name)}
  end

  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = faults) do
    %{
      faults
      | drop_responses?: false,
        wkc_offset: 0,
        disconnected: MapSet.new(),
        pending_faults: []
    }
  end

  defp valid_exchange_fault?(:drop_responses), do: true
  defp valid_exchange_fault?({:wkc_offset, delta}) when is_integer(delta), do: true
  defp valid_exchange_fault?({:disconnect, slave_name}) when is_atom(slave_name), do: true
  defp valid_exchange_fault?(_fault), do: false

  defp next_fault_info([]), do: nil
  defp next_fault_info([fault | _rest]), do: {:next_exchange, fault}
end
