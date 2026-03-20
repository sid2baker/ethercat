defmodule EtherCAT.Slave.Runtime.Outputs do
  @moduledoc false

  alias EtherCAT.Slave
  alias EtherCAT.Slave.ProcessData

  @spec write_signal(%Slave{}, atom(), term()) :: {:ok, %Slave{}} | {:error, term()}
  def write_signal(data, signal_name, value) do
    write_signals(data, [{:write, signal_name, value}])
  end

  @spec write_signals(%Slave{}, [tuple()]) :: {:ok, %Slave{}} | {:error, term()}
  def write_signals(%Slave{} = data, intents) when is_list(intents) do
    with {:ok, staged_writes} <- plan_writes(data, intents),
         {:ok, next_data} <- commit_writes(data, staged_writes) do
      {:ok, next_data}
    end
  end

  defp plan_writes(%Slave{} = data, intents) do
    Enum.reduce_while(intents, {:ok, %{}}, fn
      {:write, signal_name, value}, {:ok, staged_writes} ->
        case plan_signal_write(data, staged_writes, signal_name, value) do
          {:ok, next_writes} -> {:cont, {:ok, next_writes}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      other, _acc ->
        {:halt, {:error, {:invalid_output_intent, other}}}
    end)
  end

  defp plan_signal_write(%Slave{} = data, staged_writes, signal_name, value) do
    case Map.get(data.signal_registrations, signal_name) do
      nil ->
        {:error, {:not_registered, signal_name}}

      %{direction: :input} ->
        {:error, {:not_output, signal_name}}

      %{
        domain_id: domain_id,
        sm_key: sm_key,
        bit_offset: bit_offset,
        bit_size: bit_size,
        sm_size: sm_size,
        direction: :output
      } ->
        encoded = data.driver.encode_signal(signal_name, data.config, value)
        domain_ids = Map.get(data.output_domain_ids_by_sm || %{}, sm_key, [domain_id])

        with {:ok, current, previous_value} <-
               current_staged_value(data, staged_writes, domain_id, sm_key, sm_size),
             next_value <- set_sm_bits(current, bit_offset, bit_size, encoded) do
          {:ok,
           Map.put(
             staged_writes,
             sm_key,
             %{
               sm_key: sm_key,
               domain_ids: domain_ids,
               previous_value: previous_value,
               next_value: next_value
             }
           )}
        end
    end
  end

  defp current_staged_value(%Slave{} = data, staged_writes, domain_id, sm_key, sm_size) do
    case Map.get(staged_writes, sm_key) do
      %{next_value: next_value, previous_value: previous_value} ->
        {:ok, next_value, previous_value}

      nil ->
        with {:ok, current} <-
               ProcessData.current_output_sm_image(data, domain_id, sm_key, sm_size) do
          {:ok, current, current}
        end
    end
  end

  defp commit_writes(%Slave{} = data, staged_writes) do
    staged_writes
    |> Map.values()
    |> Enum.reduce_while({:ok, data, []}, fn staged_write, {:ok, current_data, committed} ->
      case ProcessData.stage_output_sm_image(
             current_data,
             staged_write.sm_key,
             staged_write.domain_ids,
             staged_write.next_value
           ) do
        :ok ->
          next_data =
            %{
              current_data
              | output_sm_images:
                  Map.put(
                    current_data.output_sm_images || %{},
                    staged_write.sm_key,
                    staged_write.next_value
                  )
            }

          {:cont, {:ok, next_data, [staged_write | committed]}}

        {:error, reason} ->
          rollback_writes(data, committed)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, next_data, _committed} -> {:ok, next_data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_writes(%Slave{} = data, committed) do
    Enum.each(committed, fn staged_write ->
      _ =
        ProcessData.stage_output_sm_image(
          data,
          staged_write.sm_key,
          staged_write.domain_ids,
          staged_write.previous_value
        )
    end)

    :ok
  end

  # Write `bit_size` bits from `encoded` into `sm_bytes` at `bit_offset`.
  # `encoded` is the driver's output binary; its LSB-aligned value is packed in.
  defp set_sm_bits(sm_bytes, _bit_offset, _bit_size, <<>>), do: sm_bytes

  defp set_sm_bits(sm_bytes, bit_offset, bit_size, encoded) do
    if rem(bit_offset, 8) == 0 and rem(bit_size, 8) == 0 do
      byte_off = div(bit_offset, 8)
      byte_sz = div(bit_size, 8)
      total = byte_size(sm_bytes)
      padded = encoded <> :binary.copy(<<0>>, max(0, byte_sz - byte_size(encoded)))

      binary_part(sm_bytes, 0, byte_off) <>
        binary_part(padded, 0, byte_sz) <>
        binary_part(sm_bytes, byte_off + byte_sz, total - byte_off - byte_sz)
    else
      total_bits = byte_size(sm_bytes) * 8
      <<sm_value::unsigned-little-size(total_bits)>> = sm_bytes

      encoded_bits = byte_size(encoded) * 8
      <<encoded_value::unsigned-little-size(encoded_bits)>> = encoded

      field_value =
        if encoded_bits >= bit_size do
          <<_::size(encoded_bits - bit_size), field::size(bit_size)>> =
            <<encoded_value::size(encoded_bits)>>

          field
        else
          <<field::size(bit_size)>> =
            <<0::size(bit_size - encoded_bits), encoded_value::size(encoded_bits)>>

          field
        end

      high_bits = total_bits - bit_offset - bit_size

      <<high::size(high_bits), _::size(bit_size), low::size(bit_offset)>> =
        <<sm_value::size(total_bits)>>

      <<patched_value::size(total_bits)>> =
        <<high::size(high_bits), field_value::size(bit_size), low::size(bit_offset)>>

      <<patched_value::unsigned-little-size(total_bits)>>
    end
  end
end
