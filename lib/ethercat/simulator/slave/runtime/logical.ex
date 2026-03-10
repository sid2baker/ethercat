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
    logical_end = logical_start + byte_size(request_data)

    slave
    |> active_fmmus()
    |> Enum.reduce({slave, request_data, 0}, fn fmmu, {current_slave, response_data, wkc} ->
      case overlap(
             logical_start,
             logical_end,
             fmmu.logical_start,
             fmmu.logical_start + fmmu.length
           ) do
        nil ->
          {current_slave, response_data, wkc}

        {datagram_offset, fmmu_offset, size} ->
          apply_overlap(
            current_slave,
            cmd,
            fmmu,
            request_data,
            response_data,
            datagram_offset,
            fmmu_offset,
            size,
            wkc
          )
      end
    end)
  end

  @spec active_fmmus(Device.t()) :: [map()]
  def active_fmmus(%Device{memory: memory}) do
    parse_active_fmmus(memory, 0, [])
  end

  defp parse_active_fmmus(memory, index, acc) do
    base = Registers.fmmu(index)

    if base + @fmmu_entry_size <= byte_size(memory) do
      activate = read_u8(memory, offset(Registers.fmmu_activate(index)))
      length = read_u16(memory, offset(Registers.fmmu_length(index)))

      acc =
        if activate == 0x01 and length > 0 do
          [
            %{
              index: index,
              logical_start: read_u32(memory, offset(Registers.fmmu_log_start(index))),
              length: length,
              phys_start: read_u16(memory, offset(Registers.fmmu_phys_start(index))),
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
         %{type: 0x02, phys_start: phys_start},
         request_data,
         response_data,
         datagram_offset,
         fmmu_offset,
         size,
         wkc
       )
       when cmd in [@lwr, @lrw] do
    bytes = binary_part(request_data, datagram_offset, size)
    updated_slave = ProcessImage.write_register(slave, phys_start + fmmu_offset, bytes)

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
         %{type: 0x01, phys_start: phys_start},
         _request_data,
         response_data,
         datagram_offset,
         fmmu_offset,
         size,
         wkc
       )
       when cmd in [@lrd, @lrw] do
    bytes = Device.read_register(slave, phys_start + fmmu_offset, size)
    updated_response = replace_binary(response_data, datagram_offset, bytes)
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

  defp replace_binary(binary, offset, value) do
    prefix = binary_part(binary, 0, offset)
    suffix_offset = offset + byte_size(value)
    suffix = binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
    prefix <> value <> suffix
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
