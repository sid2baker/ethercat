defmodule EtherCAT.Simulator.Slave.ESCImageTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Slave.ESC.Registers
  alias EtherCAT.Simulator.Slave.Definition
  alias EtherCAT.Simulator.Slave.Runtime.ESCImage

  test "hydrate builds initial ESC memory and EEPROM from a definition" do
    definition = Definition.build(:mailbox_device, name: :sim, dc_capable?: true)
    %{memory: memory, eeprom: eeprom} = ESCImage.hydrate(definition)

    assert byte_size(memory) == 0x1400
    assert binary_part(memory, offset(Registers.esc_type()), 1) == <<definition.esc_type>>
    assert binary_part(memory, offset(Registers.fmmu_count()), 1) == <<definition.fmmu_count>>
    assert binary_part(memory, offset(Registers.sm_count()), 1) == <<definition.sm_count>>
    assert binary_part(memory, offset(Registers.station_address()), 2) == <<0::16-little>>
    assert binary_part(memory, offset(Registers.al_status()), 2) == <<0x01, 0x00>>
    assert binary_part(memory, offset(Registers.al_status_code()), 2) == <<0::16-little>>
    assert binary_part(memory, Registers.eeprom_data(), 8) == binary_part(eeprom, 0, 8)
    assert binary_part(memory, 0x0910, 8) == <<1_000_000::64-little>>

    assert binary_part(eeprom, 0x08 * 2, 8) ==
             <<definition.vendor_id::32-little, definition.product_code::32-little>>

    assert binary_part(eeprom, 0x0C * 2, 8) ==
             <<definition.revision::32-little, definition.serial_number::32-little>>
  end

  test "maybe_load_eeprom_data refreshes the EEPROM data window" do
    definition = Definition.build(:mailbox_device, name: :sim)
    %{memory: memory, eeprom: eeprom} = ESCImage.hydrate(definition)
    {eeprom_address, _} = Registers.eeprom_address()

    memory =
      replace_binary(memory, eeprom_address, <<1::32-little>>)

    updated = ESCImage.maybe_load_eeprom_data(memory, eeprom, 0x01)

    assert binary_part(updated, Registers.eeprom_data(), 8) ==
             expected_window(eeprom, 1, 8)
  end

  test "maybe_load_eeprom_data zero pads reads beyond the EEPROM image" do
    definition = Definition.build(:mailbox_device, name: :sim)
    %{memory: memory, eeprom: eeprom} = ESCImage.hydrate(definition)
    {eeprom_address, _} = Registers.eeprom_address()
    out_of_range_word_address = div(byte_size(eeprom), 2) + 1

    memory =
      replace_binary(memory, eeprom_address, <<out_of_range_word_address::32-little>>)

    updated = ESCImage.maybe_load_eeprom_data(memory, eeprom, 0x01)

    assert binary_part(updated, Registers.eeprom_data(), 8) == :binary.copy(<<0>>, 8)
  end

  defp offset({offset, _length}), do: offset

  defp expected_window(eeprom, word_address, bytes) do
    byte_offset = word_address * 2
    available = max(byte_size(eeprom) - byte_offset, 0)
    take = min(bytes, available)
    padding = bytes - take

    window =
      if byte_offset >= byte_size(eeprom) do
        <<>>
      else
        binary_part(eeprom, byte_offset, take)
      end

    window <> :binary.copy(<<0>>, padding)
  end

  defp replace_binary(binary, offset, value) do
    prefix = binary_part(binary, 0, offset)
    suffix_offset = offset + byte_size(value)
    suffix = binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
    prefix <> value <> suffix
  end
end
