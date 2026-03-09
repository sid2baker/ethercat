defmodule EtherCAT.Slave.Runtime.Outputs do
  @moduledoc false

  alias EtherCAT.Slave
  alias EtherCAT.Slave.ProcessData

  @spec write_signal(%Slave{}, atom(), term()) :: {:ok, %Slave{}} | {:error, term()}
  def write_signal(data, signal_name, value) do
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

        with {:ok, current} <-
               ProcessData.current_output_sm_image(data, domain_id, sm_key, sm_size),
             next_value <- set_sm_bits(current, bit_offset, bit_size, encoded),
             :ok <- ProcessData.stage_output_sm_image(data, sm_key, domain_ids, next_value) do
          {:ok, %{data | output_sm_images: Map.put(data.output_sm_images, sm_key, next_value)}}
        end
    end
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
