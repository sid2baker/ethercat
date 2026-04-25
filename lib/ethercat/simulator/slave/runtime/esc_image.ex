defmodule EtherCAT.Simulator.Slave.Runtime.ESCImage do
  @moduledoc false

  alias EtherCAT.Slave.ESC.Registers
  alias EtherCAT.Simulator.Slave.Definition
  alias EtherCAT.Simulator.Slave.Runtime.Memory

  @memory_size 0x1400
  @category_start 0x40

  @spec hydrate(Definition.t()) :: %{eeprom: binary(), memory: binary()}
  def hydrate(%Definition{} = definition) do
    eeprom = build_eeprom(definition)
    memory = build_memory(definition, eeprom)
    %{eeprom: eeprom, memory: memory}
  end

  @spec maybe_load_eeprom_data(binary(), binary(), non_neg_integer()) :: binary()
  def maybe_load_eeprom_data(memory, eeprom, 0x01) when is_binary(memory) and is_binary(eeprom) do
    {eeprom_address, _} = Registers.eeprom_address()
    <<word_address::32-little>> = binary_part(memory, eeprom_address, 4)
    Memory.replace(memory, Registers.eeprom_data(), chunk(eeprom, word_address, 8))
  end

  def maybe_load_eeprom_data(memory, _eeprom, _cmd) when is_binary(memory), do: memory

  defp build_memory(definition, eeprom) do
    {esc_type, _} = Registers.esc_type()
    {fmmu_count, _} = Registers.fmmu_count()
    {sm_count, _} = Registers.sm_count()
    {station_address, _} = Registers.station_address()
    {dl_status, _} = Registers.dl_status()
    {al_status, _} = Registers.al_status()
    {al_status_code, _} = Registers.al_status_code()
    {ecat_event_mask, _} = Registers.ecat_event_mask()
    {rx_error_counter, _} = Registers.rx_error_counter()
    {wdt_divider, _} = Registers.wdt_divider()
    {wdt_sm, _} = Registers.wdt_sm()
    {wdt_status, _} = Registers.wdt_status()
    {eeprom_ecat_access, _} = Registers.eeprom_ecat_access()
    {eeprom_control, _} = Registers.eeprom_control()
    {eeprom_address, _} = Registers.eeprom_address()

    :binary.copy(<<0>>, @memory_size)
    |> Memory.replace(esc_type, <<definition.esc_type::8>>)
    |> Memory.replace(fmmu_count, <<definition.fmmu_count::8>>)
    |> Memory.replace(sm_count, <<definition.sm_count::8>>)
    |> Memory.replace(station_address, <<0::16-little>>)
    |> Memory.replace(dl_status, <<0::16-little>>)
    |> Memory.replace(al_status, Memory.encode_al_status(:init, false))
    |> Memory.replace(al_status_code, <<0::16-little>>)
    |> Memory.replace(ecat_event_mask, <<0::16-little>>)
    |> Memory.replace(rx_error_counter, <<0::64>>)
    |> Memory.replace(wdt_divider, <<0::16-little>>)
    |> Memory.replace(wdt_sm, <<0::16-little>>)
    |> Memory.replace(wdt_status, <<0::16-little>>)
    |> Memory.replace(eeprom_ecat_access, <<0x00>>)
    |> Memory.replace(eeprom_control, <<1, 0>>)
    |> Memory.replace(eeprom_address, <<0::32-little>>)
    |> Memory.replace(Registers.eeprom_data(), chunk(eeprom, 0, 8))
    |> maybe_put_dc_registers(definition.dc_capable?)
  end

  defp build_eeprom(definition) do
    sm_entries =
      (mailbox_sm_entries(definition.mailbox_config) ++
         [
           {2, definition.output_phys, definition.output_size,
            sm_ctrl(:output, definition.output_size)},
           {3, definition.input_phys, definition.input_size,
            sm_ctrl(:input, definition.input_size)}
         ])
      |> Enum.filter(fn {_index, _phys_start, length, ctrl} -> length > 0 or ctrl == 0x00 end)

    header =
      :binary.copy(<<0>>, @category_start * 2)
      |> Memory.replace(
        0x08 * 2,
        <<definition.vendor_id::32-little, definition.product_code::32-little>>
      )
      |> Memory.replace(
        0x0C * 2,
        <<definition.revision::32-little, definition.serial_number::32-little>>
      )
      |> Memory.replace(
        0x18 * 2,
        <<definition.mailbox_config.recv_offset::16-little,
          definition.mailbox_config.recv_size::16-little,
          definition.mailbox_config.send_offset::16-little,
          definition.mailbox_config.send_size::16-little>>
      )

    header <>
      sm_category(sm_entries) <>
      pdo_categories(definition.pdo_entries) <>
      <<0xFFFF::16-little, 0::16-little>>
  end

  defp maybe_put_dc_registers(memory, false), do: memory

  defp maybe_put_dc_registers(memory, true) do
    zero8 = <<0::8>>

    memory
    |> Memory.replace(0x0900, <<10::32-little, 20::32-little, 30::32-little, 40::32-little>>)
    |> Memory.replace(0x0910, <<1_000_000::64-little>>)
    |> Memory.replace(0x0918, <<1_000_100::64-little>>)
    |> Memory.replace(0x0920, <<0::64-little>>)
    |> Memory.replace(0x0928, <<0::32-little>>)
    |> Memory.replace(0x092C, <<0::32-little>>)
    |> Memory.replace(0x0930, <<0::16-little>>)
    |> Memory.replace(0x0934, <<0::16-little>>)
    |> Memory.replace(0x0980, <<0::16-little>>)
    |> Memory.replace(0x0981, zero8)
    |> Memory.replace(0x0982, <<0::16-little>>)
    |> Memory.replace(0x0990, <<0::64-little>>)
    |> Memory.replace(0x09A0, <<0::32-little>>)
    |> Memory.replace(0x09A4, <<0::32-little>>)
    |> Memory.replace(0x09A8, zero8)
    |> Memory.replace(0x09A9, zero8)
    |> Memory.replace(0x09AE, <<0::16-little>>)
    |> Memory.replace(0x09B0, <<0::64-little>>)
    |> Memory.replace(0x09B8, <<0::64-little>>)
    |> Memory.replace(0x09C0, <<0::64-little>>)
    |> Memory.replace(0x09C8, <<0::64-little>>)
  end

  defp mailbox_sm_entries(%{recv_offset: 0, recv_size: 0, send_offset: 0, send_size: 0}) do
    [{0, 0x0000, 0, 0x00}, {1, 0x0000, 0, 0x00}]
  end

  defp mailbox_sm_entries(%{
         recv_offset: recv_offset,
         recv_size: recv_size,
         send_offset: send_offset,
         send_size: send_size
       }) do
    [
      {0, recv_offset, recv_size, 0x26},
      {1, send_offset, send_size, 0x22}
    ]
  end

  defp sm_ctrl(_direction, 0), do: 0x00
  defp sm_ctrl(:output, _size), do: 0x24
  defp sm_ctrl(:input, _size), do: 0x20

  defp sm_category(sm_entries) do
    data =
      sm_entries
      |> Enum.map(fn {_index, phys_start, length, ctrl} ->
        <<phys_start::16-little, length::16-little, ctrl::8, 0::8, 0::8, 0::8>>
      end)
      |> IO.iodata_to_binary()

    <<0x0029::16-little, div(byte_size(data), 2)::16-little, data::binary>>
  end

  defp pdo_categories(pdo_entries) do
    pdo_entries
    |> Enum.sort_by(fn %{direction: direction, index: index} ->
      {pdo_direction_rank(direction), index}
    end)
    |> Enum.map(&pdo_category/1)
    |> IO.iodata_to_binary()
  end

  defp pdo_direction_rank(:output), do: 0
  defp pdo_direction_rank(:input), do: 1

  defp pdo_category(%{
         index: pdo_index,
         direction: direction,
         sm_index: sm_index,
         bit_size: bit_size
       }) do
    category_type = if direction == :input, do: 0x0032, else: 0x0033

    data =
      <<
        pdo_index::16-little,
        1::8,
        sm_index::8,
        0::32-little,
        pdo_index::16-little,
        0::24-little,
        bit_size::8,
        0::16-little
      >>

    <<category_type::16-little, div(byte_size(data), 2)::16-little, data::binary>>
  end

  defp chunk(binary, word_address, bytes) do
    offset = word_address * 2
    available = max(byte_size(binary) - offset, 0)
    take = min(bytes, available)
    padding = bytes - take

    chunk_prefix =
      if offset >= byte_size(binary) do
        <<>>
      else
        binary_part(binary, offset, take)
      end

    chunk_prefix <> :binary.copy(<<0>>, padding)
  end
end
