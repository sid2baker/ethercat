defmodule EtherCAT.Simulator.Slave.Runtime.Logical do
  @moduledoc false

  alias EtherCAT.Slave.ESC.Registers
  alias EtherCAT.Simulator.Slave.Runtime.Device
  alias EtherCAT.Simulator.Slave.Runtime.ProcessImage

  @lrd 10
  @lwr 11
  @lrw 12

  @fmmu_entry_size 16
  @spec read_write(Device.t(), 10 | 11 | 12, non_neg_integer(), binary()) ::
          {Device.t(), binary(), non_neg_integer()}
  def read_write(%Device{} = slave, cmd, logical_start, request_data) do
    logical_bit_start = logical_start * 8
    logical_bit_end = logical_bit_start + bit_size(request_data)

    slave
    |> active_fmmus()
    |> Enum.reduce({slave, request_data, 0}, fn fmmu, {current_slave, response_data, wkc} ->
      case overlap(
             logical_bit_start,
             logical_bit_end,
             fmmu.logical_bit_start,
             fmmu.logical_bit_start + fmmu.logical_bit_length
           ) do
        nil ->
          {current_slave, response_data, wkc}

        {datagram_bit_offset, fmmu_bit_offset, size_bits} ->
          apply_overlap(
            current_slave,
            cmd,
            fmmu,
            request_data,
            response_data,
            datagram_bit_offset,
            fmmu_bit_offset,
            size_bits,
            wkc
          )
      end
    end)
  end

  @spec active_fmmus(Device.t()) :: [map()]
  def active_fmmus(%Device{memory: memory}) do
    parse_active_fmmus(memory, 0, [])
  end

  @spec maps_physical_region?(Device.t(), 0x01 | 0x02, non_neg_integer(), non_neg_integer()) ::
          boolean()
  def maps_physical_region?(%Device{} = slave, type, phys_start, size)
      when type in [0x01, 0x02] and is_integer(phys_start) and phys_start >= 0 and
             is_integer(size) and size >= 0 do
    required_bits = size * 8

    Enum.any?(active_fmmus(slave), fn fmmu ->
      fmmu.type == type and fmmu.phys_start == phys_start and fmmu.phys_start_bit == 0 and
        fmmu.logical_bit_length >= required_bits
    end)
  end

  defp parse_active_fmmus(memory, index, acc) do
    base = Registers.fmmu(index)

    if base + @fmmu_entry_size <= byte_size(memory) do
      activate = read_u8(memory, offset(Registers.fmmu_activate(index)))
      length = read_u16(memory, offset(Registers.fmmu_length(index)))

      acc =
        if activate == 0x01 and length > 0 do
          logical_start = read_u32(memory, offset(Registers.fmmu_log_start(index)))
          logical_start_bit = read_u8(memory, offset(Registers.fmmu_log_start_bit(index)))
          logical_stop_bit = read_u8(memory, offset(Registers.fmmu_log_stop_bit(index)))
          phys_start = read_u16(memory, offset(Registers.fmmu_phys_start(index)))
          phys_start_bit = read_u8(memory, offset(Registers.fmmu_phys_start_bit(index)))
          logical_bit_length = fmmu_bit_length(length, logical_start_bit, logical_stop_bit)

          [
            %{
              index: index,
              logical_start: logical_start,
              length: length,
              logical_start_bit: logical_start_bit,
              logical_stop_bit: logical_stop_bit,
              logical_bit_start: logical_start * 8 + logical_start_bit,
              logical_bit_length: logical_bit_length,
              phys_start: phys_start,
              phys_start_bit: phys_start_bit,
              physical_bit_start: phys_start * 8 + phys_start_bit,
              type: read_u8(memory, offset(Registers.fmmu_type(index)))
            }
            | acc
          ]
        else
          acc
        end

      parse_active_fmmus(memory, index + 1, acc)
    else
      Enum.reverse(acc)
    end
  end

  defp apply_overlap(
         slave,
         cmd,
         %{type: 0x02, physical_bit_start: physical_bit_start},
         request_data,
         response_data,
         datagram_bit_offset,
         fmmu_bit_offset,
         size_bits,
         wkc
       )
       when cmd in [@lwr, @lrw] do
    bits = extract_bits(request_data, datagram_bit_offset, size_bits)
    updated_slave = ProcessImage.write_bits(slave, physical_bit_start + fmmu_bit_offset, bits)

    write_wkc =
      case cmd do
        @lwr -> 1
        @lrw -> 2
      end

    {updated_slave, response_data, wkc + write_wkc}
  end

  defp apply_overlap(
         slave,
         cmd,
         %{type: 0x01, physical_bit_start: physical_bit_start},
         _request_data,
         response_data,
         datagram_bit_offset,
         fmmu_bit_offset,
         size_bits,
         wkc
       )
       when cmd in [@lrd, @lrw] do
    bits = ProcessImage.read_bits(slave, physical_bit_start + fmmu_bit_offset, size_bits)
    updated_response = replace_bits(response_data, datagram_bit_offset, bits)
    {slave, updated_response, wkc + 1}
  end

  defp apply_overlap(
         slave,
         _cmd,
         _fmmu,
         _request_data,
         response_data,
         _datagram_offset,
         _fmmu_offset,
         _size,
         wkc
       ) do
    {slave, response_data, wkc}
  end

  defp replace_bits(binary, bit_offset, bits) do
    bits
    |> Enum.with_index(bit_offset)
    |> Enum.reduce(binary, fn {bit, current_offset}, current_binary ->
      write_lsb_bit(current_binary, current_offset, bit)
    end)
  end

  defp overlap(start_a, end_a, start_b, end_b) do
    overlap_start = max(start_a, start_b)
    overlap_end = min(end_a, end_b)

    if overlap_start < overlap_end do
      {overlap_start - start_a, overlap_start - start_b, overlap_end - overlap_start}
    else
      nil
    end
  end

  defp offset({offset, _length}), do: offset

  defp fmmu_bit_length(length, logical_start_bit, logical_stop_bit) do
    (length - 1) * 8 + logical_stop_bit - logical_start_bit + 1
  end

  defp extract_bits(binary, bit_offset, bit_size) do
    Enum.map(bit_offset..(bit_offset + bit_size - 1), &read_lsb_bit(binary, &1))
  end

  defp read_lsb_bit(binary, bit_offset) do
    byte_offset = div(bit_offset, 8)
    bit_in_byte = rem(bit_offset, 8)
    <<byte::8>> = binary_part(binary, byte_offset, 1)

    <<_prefix::bitstring-size(7 - bit_in_byte), bit::1, _suffix::bitstring-size(bit_in_byte)>> =
      <<byte::8>>

    bit
  end

  defp write_lsb_bit(binary, bit_offset, bit) when bit in [0, 1] do
    byte_offset = div(bit_offset, 8)
    bit_in_byte = rem(bit_offset, 8)
    <<byte::8>> = binary_part(binary, byte_offset, 1)

    <<prefix::bitstring-size(7 - bit_in_byte), _current::1, suffix::bitstring-size(bit_in_byte)>> =
      <<byte::8>>

    <<updated_byte::8>> = <<prefix::bitstring, bit::1, suffix::bitstring>>

    prefix_binary = binary_part(binary, 0, byte_offset)
    suffix_offset = byte_offset + 1
    suffix_binary = binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
    prefix_binary <> <<updated_byte::8>> <> suffix_binary
  end

  defp read_u8(memory, offset) do
    <<value::8>> = binary_part(memory, offset, 1)
    value
  end

  defp read_u16(memory, offset) do
    <<value::16-little>> = binary_part(memory, offset, 2)
    value
  end

  defp read_u32(memory, offset) do
    <<value::32-little>> = binary_part(memory, offset, 4)
    value
  end
end
