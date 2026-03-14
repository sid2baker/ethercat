defmodule EtherCAT.Simulator.Slave.Runtime.Memory do
  @moduledoc false

  @type al_state :: :bootstrap | :init | :op | :preop | :safeop

  @spec replace(binary(), non_neg_integer(), binary()) :: binary()
  def replace(binary, offset, value) do
    prefix = binary_part(binary, 0, offset)
    suffix_offset = offset + byte_size(value)
    suffix = binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
    prefix <> value <> suffix
  end

  @spec read_lsb_bit(binary(), non_neg_integer()) :: 0 | 1
  def read_lsb_bit(binary, bit_offset) do
    byte_offset = div(bit_offset, 8)
    bit_in_byte = rem(bit_offset, 8)
    <<byte::8>> = binary_part(binary, byte_offset, 1)

    <<_prefix::bitstring-size(7 - bit_in_byte), bit::1, _suffix::bitstring-size(bit_in_byte)>> =
      <<byte::8>>

    bit
  end

  @spec write_lsb_bit(binary(), non_neg_integer(), 0 | 1) :: binary()
  def write_lsb_bit(binary, bit_offset, bit) when bit in [0, 1] do
    byte_offset = div(bit_offset, 8)
    bit_in_byte = rem(bit_offset, 8)
    <<byte::8>> = binary_part(binary, byte_offset, 1)

    <<prefix::bitstring-size(7 - bit_in_byte), _current::1, suffix::bitstring-size(bit_in_byte)>> =
      <<byte::8>>

    <<updated_byte::8>> = <<prefix::bitstring, bit::1, suffix::bitstring>>
    replace(binary, byte_offset, <<updated_byte::8>>)
  end

  @spec encode_al_status(al_state(), boolean()) :: <<_::16>>
  def encode_al_status(al_state, error?) do
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
