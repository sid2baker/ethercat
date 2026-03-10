defmodule EtherCAT.Support.Slave.Device do
  @moduledoc false

  @memory_size 0x1400
  @alerr_none 0x0000
  @alerr_invalid_state_change 0x0011
  @alerr_unknown_state 0x0012

  @type t :: %__MODULE__{
          name: atom(),
          position: non_neg_integer(),
          station: non_neg_integer(),
          state: :init | :preop | :safeop | :op | :bootstrap,
          al_error?: boolean(),
          al_status_code: non_neg_integer(),
          eeprom: binary(),
          memory: binary(),
          output_phys: non_neg_integer(),
          input_phys: non_neg_integer(),
          mirror_output_to_input?: boolean()
        }

  defstruct [
    :name,
    :position,
    :station,
    :state,
    :al_error?,
    :al_status_code,
    :eeprom,
    :memory,
    :output_phys,
    :input_phys,
    :mirror_output_to_input?
  ]

  @spec new(map(), non_neg_integer()) :: t()
  def new(fixture, position) do
    %__MODULE__{
      name: fixture.name,
      position: position,
      station: 0,
      state: :init,
      al_error?: false,
      al_status_code: 0,
      eeprom: fixture.eeprom,
      memory: fixture.memory,
      output_phys: fixture.output_phys,
      input_phys: fixture.input_phys,
      mirror_output_to_input?: fixture.mirror_output_to_input?
    }
  end

  @spec read_register(t(), non_neg_integer(), pos_integer()) :: binary()
  def read_register(%__MODULE__{memory: memory}, offset, length) do
    binary_part(memory, offset, length)
  end

  @spec write_register(t(), non_neg_integer(), binary()) :: t()
  def write_register(%__MODULE__{} = slave, 0x0010, <<station::16-little>>) do
    slave
    |> Map.put(:station, station)
    |> write_memory(0x0010, <<station::16-little>>)
  end

  def write_register(%__MODULE__{} = slave, 0x0120, <<control::16-little>>) do
    <<low::8, _high::8>> = <<control::16-little>>
    request = rem(low, 16)

    slave
    |> write_memory(0x0120, <<control::16-little>>)
    |> apply_al_control(request)
  end

  def write_register(%__MODULE__{} = slave, 0x0502, <<low::8, high::8>> = control) do
    slave =
      slave
      |> write_memory(0x0502, control)
      |> maybe_load_eeprom_data(high)

    # Keep the size-bit set in the low byte for 8-byte reads.
    write_memory(slave, 0x0502, <<max(low, 1)::8, high::8>>)
  end

  def write_register(%__MODULE__{} = slave, offset, data) do
    write_memory(slave, offset, data)
  end

  @spec logical_read_write(t(), 10 | 11 | 12, non_neg_integer(), binary()) ::
          {t(), binary(), non_neg_integer()}
  def logical_read_write(%__MODULE__{} = slave, cmd, logical_start, request_data) do
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
          apply_logical_overlap(
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

  defp apply_logical_overlap(
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
       when cmd in [11, 12] do
    bytes = binary_part(request_data, datagram_offset, size)

    updated_slave =
      slave
      |> write_memory(phys_start + fmmu_offset, bytes)
      |> maybe_mirror_output(bytes)

    write_wkc =
      case cmd do
        11 -> 1
        12 -> 2
      end

    {updated_slave, response_data, wkc + write_wkc}
  end

  defp apply_logical_overlap(
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
       when cmd in [10, 12] do
    bytes = read_register(slave, phys_start + fmmu_offset, size)
    updated_response = replace_binary(response_data, datagram_offset, bytes)
    {slave, updated_response, wkc + 1}
  end

  defp apply_logical_overlap(
         slave,
         _cmd,
         _fmmu,
         _request_data,
         response_data,
         _src_offset,
         _dst_offset,
         _size,
         wkc
       ) do
    {slave, response_data, wkc}
  end

  defp active_fmmus(%__MODULE__{memory: memory}) do
    fmmu_region = binary_part(memory, 0x0600, @memory_size - 0x0600)
    parse_fmmus(fmmu_region, 0, [])
  end

  defp parse_fmmus(<<>>, _index, acc), do: Enum.reverse(acc)

  defp parse_fmmus(
         <<logical_start::32-little, length::16-little, _log_start_bit::8, _log_stop_bit::8,
           phys_start::16-little, _phys_start_bit::8, type::8, activate::8, _rest::24,
           tail::binary>>,
         index,
         acc
       ) do
    acc =
      if activate == 0x01 and length > 0 do
        [
          %{
            index: index,
            logical_start: logical_start,
            length: length,
            phys_start: phys_start,
            type: type
          }
          | acc
        ]
      else
        acc
      end

    parse_fmmus(tail, index + 1, acc)
  end

  defp maybe_load_eeprom_data(slave, 0x01) do
    <<word_address::32-little>> = read_register(slave, 0x0504, 4)
    data = chunk(slave.eeprom, word_address, 8)
    write_memory(slave, 0x0508, data)
  end

  defp maybe_load_eeprom_data(slave, _cmd), do: slave

  defp maybe_mirror_output(
         %__MODULE__{mirror_output_to_input?: true, input_phys: input_phys} = slave,
         bytes
       ) do
    write_memory(slave, input_phys, bytes)
  end

  defp maybe_mirror_output(slave, _bytes), do: slave

  defp apply_al_control(slave, request) do
    case decode_al_request(request) do
      {:ok, target_state} ->
        if valid_transition?(slave.state, target_state) do
          commit_al_state(slave, target_state, false, @alerr_none)
        else
          commit_al_state(slave, slave.state, true, @alerr_invalid_state_change)
        end

      :error ->
        commit_al_state(slave, slave.state, true, @alerr_unknown_state)
    end
  end

  defp decode_al_request(0x01), do: {:ok, :init}
  defp decode_al_request(0x02), do: {:ok, :preop}
  defp decode_al_request(0x03), do: {:ok, :bootstrap}
  defp decode_al_request(0x04), do: {:ok, :safeop}
  defp decode_al_request(0x08), do: {:ok, :op}
  defp decode_al_request(_request), do: :error

  defp valid_transition?(state, state), do: true
  defp valid_transition?(_state, :init), do: true
  defp valid_transition?(:init, :preop), do: true
  defp valid_transition?(:init, :bootstrap), do: true
  defp valid_transition?(:preop, :safeop), do: true
  defp valid_transition?(:preop, :bootstrap), do: true
  defp valid_transition?(:safeop, :preop), do: true
  defp valid_transition?(:safeop, :op), do: true
  defp valid_transition?(:op, :safeop), do: true
  defp valid_transition?(:op, :preop), do: true
  defp valid_transition?(:bootstrap, :preop), do: true
  defp valid_transition?(:bootstrap, :init), do: true
  defp valid_transition?(_from, _to), do: false

  defp commit_al_state(slave, state, error?, status_code) do
    slave
    |> Map.put(:state, state)
    |> Map.put(:al_error?, error?)
    |> Map.put(:al_status_code, status_code)
    |> write_memory(0x0130, encode_al_status(state, error?))
    |> write_memory(0x0134, <<status_code::16-little>>)
  end

  defp write_memory(%__MODULE__{memory: memory} = slave, offset, data) do
    %{slave | memory: replace_binary(memory, offset, data)}
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

  defp chunk(binary, word_address, bytes) do
    offset = word_address * 2
    available = max(byte_size(binary) - offset, 0)
    take = min(bytes, available)
    padding = bytes - take
    binary_part(binary, offset, take) <> :binary.copy(<<0>>, padding)
  end

  defp encode_al_status(al_state, error?) do
    state_code =
      case al_state do
        :init -> 0x01
        :preop -> 0x02
        :bootstrap -> 0x03
        :safeop -> 0x04
        :op -> 0x08
      end

    error_bit = if error?, do: 1, else: 0
    <<0::3, error_bit::1, state_code::4, 0::8>>
  end
end
