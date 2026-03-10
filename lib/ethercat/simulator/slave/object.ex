defmodule EtherCAT.Simulator.Slave.Object do
  @moduledoc false

  alias EtherCAT.Simulator.Slave.Value

  @abort_write_only 0x0601_0001
  @abort_read_only 0x0601_0002
  @abort_object_not_found 0x0602_0000
  @abort_hardware_error 0x0606_0000
  @abort_type_mismatch 0x0607_0010
  @abort_data_device_state 0x0800_0022

  @type access :: :ro | :rw | :wo

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          subindex: non_neg_integer(),
          name: atom() | nil,
          type: Value.scalar_type(),
          value: term(),
          access: access(),
          read_states: :all | [atom()],
          write_states: :all | [atom()],
          unit: binary() | nil,
          scale: number(),
          offset: number(),
          group: atom() | nil
        }

  @enforce_keys [:index, :subindex, :type, :value]
  defstruct [
    :index,
    :subindex,
    :name,
    :type,
    :value,
    :unit,
    :group,
    access: :rw,
    read_states: :all,
    write_states: :all,
    scale: 1,
    offset: 0
  ]

  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end

  @spec encode(t(), atom()) :: {:ok, binary()} | {:error, non_neg_integer()}
  def encode(%__MODULE__{} = entry, state) do
    cond do
      entry.access == :wo ->
        {:error, @abort_write_only}

      not allowed_state?(entry.read_states, state) ->
        {:error, @abort_data_device_state}

      true ->
        entry
        |> metadata()
        |> Value.encode_binary(entry.value)
        |> case do
          {:ok, binary} -> {:ok, binary}
          {:error, _} -> {:error, @abort_hardware_error}
        end
    end
  end

  @spec decode(t(), atom(), binary()) :: {:ok, t()} | {:error, non_neg_integer()}
  def decode(%__MODULE__{} = entry, state, binary) do
    cond do
      entry.access == :ro ->
        {:error, @abort_read_only}

      not allowed_state?(entry.write_states, state) ->
        {:error, @abort_data_device_state}

      true ->
        expected_size = Value.byte_width(metadata(entry))

        if byte_size(binary) == expected_size do
          updated = %{entry | value: Value.decode_binary(metadata(entry), binary)}
          {:ok, updated}
        else
          {:error, @abort_type_mismatch}
        end
    end
  end

  @spec set_value(t(), term()) :: {:ok, t()} | {:error, non_neg_integer()}
  def set_value(%__MODULE__{} = entry, value) do
    case Value.encode_binary(metadata(entry), value) do
      {:ok, _binary} -> {:ok, %{entry | value: value}}
      {:error, _} -> {:error, @abort_type_mismatch}
    end
  end

  @spec get_value(t()) :: term()
  def get_value(%__MODULE__{value: value}), do: value

  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{} = entry) do
    %{
      type: entry.type,
      scale: entry.scale,
      offset: entry.offset
    }
  end

  @spec object_not_found_abort() :: non_neg_integer()
  def object_not_found_abort, do: @abort_object_not_found

  defp allowed_state?(:all, _state), do: true
  defp allowed_state?(states, state) when is_list(states), do: state in states
end
