defmodule EtherCAT.Domain.Image do
  @moduledoc false

  alias EtherCAT.Domain
  alias EtherCAT.Domain.Freshness

  @type table :: atom() | :ets.tid()
  @type domain_status :: %{
          required(:last_valid_cycle_at_us) => integer() | nil,
          required(:stale_after_us) => pos_integer()
        }

  @spec lookup_table(Domain.domain_id()) :: {:ok, table()} | {:error, :not_found}
  def lookup_table(domain_id) when is_atom(domain_id) do
    case :ets.whereis(domain_id) do
      :undefined -> {:error, :not_found}
      table -> {:ok, table}
    end
  end

  @spec insert_registration_entry(table(), Domain.pdo_key(), pos_integer(), :input | :output) ::
          true
  def insert_registration_entry(table, key, size, direction) do
    value = if direction == :input, do: :unset, else: :binary.copy(<<0>>, size)
    :ets.insert(table, {key, value, initial_sample_meta(direction)})
  end

  @spec put_domain_status(table(), integer() | nil, pos_integer()) :: true
  def put_domain_status(table, last_valid_cycle_at_us, stale_after_us)
      when is_integer(stale_after_us) and stale_after_us > 0 do
    :ets.insert(
      table,
      {Freshness.status_key(),
       %{last_valid_cycle_at_us: last_valid_cycle_at_us, stale_after_us: stale_after_us}}
    )
  end

  @spec domain_status(table()) :: domain_status()
  def domain_status(table) do
    case :ets.lookup(table, Freshness.status_key()) do
      [{_, %{last_valid_cycle_at_us: last_valid_cycle_at_us, stale_after_us: stale_after_us}}] ->
        %{last_valid_cycle_at_us: last_valid_cycle_at_us, stale_after_us: stale_after_us}

      [] ->
        %{last_valid_cycle_at_us: nil, stale_after_us: 1}
    end
  end

  @spec write(table(), Domain.pdo_key(), binary(), integer()) :: :ok | {:error, :not_found}
  def write(table, key, binary, updated_at_us) do
    case :ets.update_element(table, key, [{2, binary}, {3, {:output, updated_at_us}}]) do
      true -> :ok
      false -> {:error, :not_found}
    end
  end

  @spec read(table(), Domain.pdo_key()) :: {:ok, binary() | :unset} | {:error, :not_found}
  def read(table, key), do: stored_value(table, key)

  @spec sample(table(), Domain.pdo_key()) ::
          {:ok,
           %{
             value: binary(),
             updated_at_us: integer() | nil,
             changed_at_us: integer() | nil,
             freshness: Freshness.snapshot() | nil
           }}
          | {:error, :not_found | :not_ready}
  def sample(table, key) do
    case stored_entry(table, key) do
      {:ok, :unset, _meta} ->
        {:error, :not_ready}

      {:ok, value, meta} ->
        {:ok, sample_payload(table, value, meta)}

      {:error, :not_found} ->
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

  @spec stored_entry(table(), Domain.pdo_key()) ::
          {:ok, binary() | :unset, {:input | :output, integer() | nil}} | {:error, :not_found}
  def stored_entry(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value, meta}] -> {:ok, value, meta}
      [] -> {:error, :not_found}
    end
  end

  @spec stored_value(table(), Domain.pdo_key()) :: {:ok, binary() | :unset} | {:error, :not_found}
  def stored_value(table, key) do
    case stored_entry(table, key) do
      {:ok, value, _meta} -> {:ok, value}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @spec stored_value(table(), Domain.pdo_key(), term()) :: term()
  def stored_value(table, key, default) do
    case stored_value(table, key) do
      {:ok, value} -> value
      {:error, :not_found} -> default
    end
  end

  @spec update_input(table(), Domain.pdo_key(), binary(), integer()) :: true
  def update_input(table, key, new_val, changed_at_us) do
    :ets.update_element(table, key, [{2, new_val}, {3, {:input, changed_at_us}}])
  end

  @spec initial_sample_meta(:input | :output) :: {:input | :output, nil}
  def initial_sample_meta(direction) when direction in [:input, :output], do: {direction, nil}

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
  defp replacement_value({:error, :not_found}, size), do: :binary.copy(<<0>>, size)

  defp binary_pad(data, size) when byte_size(data) >= size, do: binary_part(data, 0, size)
  defp binary_pad(data, size), do: data <> :binary.copy(<<0>>, size - byte_size(data))

  defp sample_payload(table, value, {:input, changed_at_us}) do
    %{last_valid_cycle_at_us: last_valid_cycle_at_us, stale_after_us: stale_after_us} =
      domain_status(table)

    %{
      value: value,
      updated_at_us: last_valid_cycle_at_us,
      changed_at_us: changed_at_us,
      freshness: Freshness.snapshot(last_valid_cycle_at_us, stale_after_us)
    }
  end

  defp sample_payload(_table, value, {:output, updated_at_us}) do
    %{
      value: value,
      updated_at_us: updated_at_us,
      changed_at_us: updated_at_us,
      freshness: nil
    }
  end
end
