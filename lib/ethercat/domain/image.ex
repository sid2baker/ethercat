defmodule EtherCAT.Domain.Image do
  @moduledoc false

  alias EtherCAT.Domain

  @spec insert_registration_entry(atom(), Domain.pdo_key(), pos_integer(), :input | :output) ::
          true
  def insert_registration_entry(table, key, size, direction) do
    value = if direction == :input, do: :unset, else: :binary.copy(<<0>>, size)
    :ets.insert(table, {key, value, initial_sample_meta(direction)})
  end

  @spec write(atom(), Domain.pdo_key(), binary(), integer()) :: :ok | {:error, :not_found}
  def write(table, key, binary, updated_at_us) do
    case :ets.update_element(table, key, [{2, binary}, {3, updated_at_us}]) do
      true -> :ok
      false -> {:error, :not_found}
    end
  end

  @spec read(atom(), Domain.pdo_key()) :: {:ok, binary() | :unset} | :error
  def read(table, key), do: stored_value(table, key)

  @spec sample(atom(), Domain.pdo_key()) ::
          {:ok, %{value: binary(), updated_at_us: integer() | nil}}
          | {:error, :not_found | :not_ready}
  def sample(table, key) do
    case stored_entry(table, key) do
      {:ok, :unset, _meta} ->
        {:error, :not_ready}

      {:ok, value, meta} ->
        {:ok, %{value: value, updated_at_us: sample_updated_at_us(meta)}}

      :error ->
        {:error, :not_found}
    end
  end

  @spec build_frame(
          non_neg_integer(),
          [{non_neg_integer(), pos_integer(), Domain.pdo_key()}],
          atom()
        ) ::
          binary()
  def build_frame(image_size, output_patches, table) do
    zeros = :binary.copy(<<0>>, image_size)
    iodata = build_iodata(zeros, output_patches, table, 0)
    :erlang.iolist_to_binary(iodata)
  end

  @spec stored_entry(atom(), Domain.pdo_key()) ::
          {:ok, binary() | :unset, term()} | :error
  def stored_entry(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value, meta}] -> {:ok, value, meta}
      [] -> :error
    end
  end

  @spec stored_value(atom(), Domain.pdo_key()) :: {:ok, binary() | :unset} | :error
  def stored_value(table, key) do
    case stored_entry(table, key) do
      {:ok, value, _meta} -> {:ok, value}
      :error -> :error
    end
  end

  @spec stored_value(atom(), Domain.pdo_key(), term()) :: term()
  def stored_value(table, key, default) do
    case stored_value(table, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @spec sample_updated_at_us(term()) :: integer() | nil
  def sample_updated_at_us(updated_at_us) when is_integer(updated_at_us), do: updated_at_us
  def sample_updated_at_us(_meta), do: nil

  @spec update_input(atom(), Domain.pdo_key(), binary(), integer()) :: true
  def update_input(table, key, new_val, updated_at_us) do
    :ets.update_element(table, key, [{2, new_val}, {3, updated_at_us}])
  end

  @spec initial_sample_meta(:input | :output) :: nil
  def initial_sample_meta(_direction), do: nil

  defp build_iodata(frame, [], _table, cursor) do
    [binary_part(frame, cursor, byte_size(frame) - cursor)]
  end

  defp build_iodata(frame, [{offset, size, key} | rest], table, cursor) do
    prefix_len = offset - cursor
    replacement = table |> stored_value(key) |> replacement_value(size)

    [
      binary_part(frame, cursor, prefix_len),
      replacement
      | build_iodata(frame, rest, table, offset + size)
    ]
  end

  defp replacement_value({:ok, value}, size), do: binary_pad(value, size)
  defp replacement_value(:error, size), do: :binary.copy(<<0>>, size)

  defp binary_pad(data, size) when byte_size(data) >= size, do: binary_part(data, 0, size)
  defp binary_pad(data, size), do: data <> :binary.copy(<<0>>, size - byte_size(data))
end
