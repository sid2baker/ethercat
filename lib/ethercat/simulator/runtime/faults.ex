defmodule EtherCAT.Simulator.Runtime.Faults do
  @moduledoc false

  @type fault ::
          :drop_responses
          | {:wkc_offset, integer()}
          | {:disconnect, atom()}

  @type t :: %__MODULE__{
          drop_responses?: boolean(),
          wkc_offset: integer(),
          disconnected: MapSet.t(atom())
        }

  @enforce_keys [:drop_responses?, :wkc_offset, :disconnected]
  defstruct [:drop_responses?, :wkc_offset, :disconnected]

  @spec new() :: t()
  def new do
    %__MODULE__{
      drop_responses?: false,
      wkc_offset: 0,
      disconnected: MapSet.new()
    }
  end

  @spec info(t()) :: map()
  def info(%__MODULE__{} = faults) do
    %{
      drop_responses?: faults.drop_responses?,
      wkc_offset: faults.wkc_offset,
      disconnected: MapSet.to_list(faults.disconnected)
    }
  end

  @spec inject(t(), fault()) :: t()
  def inject(%__MODULE__{} = faults, :drop_responses) do
    %{faults | drop_responses?: true}
  end

  def inject(%__MODULE__{} = faults, {:wkc_offset, delta}) when is_integer(delta) do
    %{faults | wkc_offset: delta}
  end

  def inject(%__MODULE__{} = faults, {:disconnect, slave_name}) when is_atom(slave_name) do
    %{faults | disconnected: MapSet.put(faults.disconnected, slave_name)}
  end

  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = faults) do
    %{faults | drop_responses?: false, wkc_offset: 0, disconnected: MapSet.new()}
  end
end
