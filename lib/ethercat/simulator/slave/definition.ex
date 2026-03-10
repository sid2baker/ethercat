defmodule EtherCAT.Simulator.Slave.Definition do
  @moduledoc false

  @memory_size 0x1400
  @category_start 0x40

  alias EtherCAT.Simulator.Slave.Object
  alias EtherCAT.Simulator.Slave.Profile

  @type t :: %{
          name: atom(),
          profile: atom(),
          behavior: module(),
          vendor_id: non_neg_integer(),
          product_code: non_neg_integer(),
          revision: non_neg_integer(),
          serial_number: non_neg_integer(),
          esc_type: byte(),
          fmmu_count: pos_integer(),
          sm_count: pos_integer(),
          output_phys: non_neg_integer(),
          output_size: non_neg_integer(),
          input_phys: non_neg_integer(),
          input_size: non_neg_integer(),
          mirror_output_to_input?: boolean(),
          pdo_entries: [map()],
          signals: %{optional(atom()) => map()},
          mailbox_config: %{
            recv_offset: non_neg_integer(),
            recv_size: non_neg_integer(),
            send_offset: non_neg_integer(),
            send_size: non_neg_integer()
          },
          objects: %{optional({non_neg_integer(), non_neg_integer()}) => Object.t()},
          dc_capable?: boolean(),
          memory: binary(),
          eeprom: binary()
        }

  @spec build(atom(), keyword()) :: t()
  def build(profile, opts \\ []) do
    profile_spec = Profile.spec(profile, opts)
    name = Keyword.get(opts, :name, :sim)
    vendor_id = Keyword.get(opts, :vendor_id, profile_spec.vendor_id)
    product_code = Keyword.get(opts, :product_code, profile_spec.product_code)
    revision = Keyword.get(opts, :revision, profile_spec.revision)
    serial_number = Keyword.get(opts, :serial_number, profile_spec.serial_number)
    esc_type = Keyword.get(opts, :esc_type, profile_spec.esc_type)
    fmmu_count = Keyword.get(opts, :fmmu_count, profile_spec.fmmu_count)
    sm_count = Keyword.get(opts, :sm_count, profile_spec.sm_count)
    output_phys = Keyword.get(opts, :output_phys, profile_spec.output_phys)
    output_size = Keyword.get(opts, :output_size, profile_spec.output_size)
    input_phys = Keyword.get(opts, :input_phys, profile_spec.input_phys)
    input_size = Keyword.get(opts, :input_size, profile_spec.input_size)

    mirror_output_to_input? =
      Keyword.get(opts, :mirror_output_to_input?, profile_spec.mirror_output_to_input?)

    mailbox_config = Keyword.get(opts, :mailbox_config, profile_spec.mailbox_config)
    objects = Keyword.get(opts, :objects, profile_spec.objects)
    pdo_entries = Keyword.get(opts, :pdo_entries, profile_spec.pdo_entries)
    signals = Keyword.get(opts, :signals, profile_spec.signals)
    dc_capable? = Keyword.get(opts, :dc_capable?, profile_spec.dc_capable?)
    behavior = Keyword.get(opts, :behavior, profile_spec.behavior)

    sm_entries =
      (mailbox_sm_entries(mailbox_config) ++
         [
           {2, output_phys, output_size, sm_ctrl(:output, output_size)},
           {3, input_phys, input_size, sm_ctrl(:input, input_size)}
         ])
      |> Enum.filter(fn {_index, _phys_start, length, ctrl} -> length > 0 or ctrl == 0x00 end)

    eeprom =
      build_eeprom(
        vendor_id,
        product_code,
        revision,
        serial_number,
        mailbox_config,
        sm_entries,
        pdo_entries
      )

    memory =
      :binary.copy(<<0>>, @memory_size)
      |> put_binary(0x0000, <<esc_type::8>>)
      |> put_binary(0x0004, <<fmmu_count::8>>)
      |> put_binary(0x0005, <<sm_count::8>>)
      |> put_binary(0x0010, <<0::16-little>>)
      |> put_binary(0x0110, <<0::16-little>>)
      |> put_binary(0x0130, encode_al_status(:init, false))
      |> put_binary(0x0134, <<0::16-little>>)
      |> put_binary(0x0200, <<0::16-little>>)
      |> put_binary(0x0300, <<0::64>>)
      |> put_binary(0x0400, <<0::16-little>>)
      |> put_binary(0x0420, <<0::16-little>>)
      |> put_binary(0x0440, <<0::16-little>>)
      |> put_binary(0x0500, <<0x00>>)
      |> put_binary(0x0502, <<1, 0>>)
      |> put_binary(0x0504, <<0::32-little>>)
      |> put_binary(0x0508, chunk(eeprom, 0, 8))
      |> maybe_put_dc_registers(dc_capable?)

    %{
      name: name,
      profile: profile_spec.profile,
      behavior: behavior,
      vendor_id: vendor_id,
      product_code: product_code,
      revision: revision,
      serial_number: serial_number,
      esc_type: esc_type,
      fmmu_count: fmmu_count,
      sm_count: sm_count,
      output_phys: output_phys,
      output_size: output_size,
      input_phys: input_phys,
      input_size: input_size,
      mirror_output_to_input?: mirror_output_to_input?,
      pdo_entries: pdo_entries,
      signals: signals,
      mailbox_config: mailbox_config,
      objects: objects,
      dc_capable?: dc_capable?,
      memory: memory,
      eeprom: eeprom
    }
  end

  @spec digital_io(keyword()) :: t()
  def digital_io(opts \\ []), do: build(:digital_io, opts)

  @spec lan9252_demo(keyword()) :: t()
  def lan9252_demo(opts \\ []), do: build(:lan9252_demo, opts)

  @spec mailbox_device(keyword()) :: t()
  def mailbox_device(opts \\ []), do: build(:mailbox_device, opts)

  @spec analog_io(keyword()) :: t()
  def analog_io(opts \\ []), do: build(:analog_io, opts)

  @spec temperature_input(keyword()) :: t()
  def temperature_input(opts \\ []), do: build(:temperature_input, opts)

  @spec servo_drive(keyword()) :: t()
  def servo_drive(opts \\ []), do: build(:servo_drive, opts)

  @spec coupler(keyword()) :: t()
  def coupler(opts \\ []), do: build(:coupler, opts)

  defp maybe_put_dc_registers(memory, false), do: memory

  defp maybe_put_dc_registers(memory, true) do
    memory
    |> put_binary(0x0900, <<10::32-little, 20::32-little, 30::32-little, 40::32-little>>)
    |> put_binary(0x0910, <<1_000_000::64-little>>)
    |> put_binary(0x0918, <<1_000_100::64-little>>)
    |> put_binary(0x0920, <<0::64-little>>)
    |> put_binary(0x0928, <<0::32-little>>)
    |> put_binary(0x092C, <<0::32-little>>)
    |> put_binary(0x0930, <<0::16-little>>)
    |> put_binary(0x0934, <<0::16-little>>)
    |> put_binary(0x0980, <<0::16-little>>)
    |> put_binary(0x0981, <<0::8>>)
    |> put_binary(0x0982, <<0::16-little>>)
    |> put_binary(0x0990, <<0::64-little>>)
    |> put_binary(0x09A0, <<0::32-little>>)
    |> put_binary(0x09A4, <<0::32-little>>)
    |> put_binary(0x09A8, <<0::8>>)
    |> put_binary(0x09A9, <<0::8>>)
    |> put_binary(0x09AE, <<0::16-little>>)
    |> put_binary(0x09B0, <<0::64-little>>)
    |> put_binary(0x09B8, <<0::64-little>>)
    |> put_binary(0x09C0, <<0::64-little>>)
    |> put_binary(0x09C8, <<0::64-little>>)
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

  defp build_eeprom(
         vendor_id,
         product_code,
         revision,
         serial_number,
         mailbox_config,
         sm_entries,
         pdo_entries
       ) do
    header =
      :binary.copy(<<0>>, @category_start * 2)
      |> put_binary(0x08 * 2, <<vendor_id::32-little, product_code::32-little>>)
      |> put_binary(0x0C * 2, <<revision::32-little, serial_number::32-little>>)
      |> put_binary(
        0x18 * 2,
        <<mailbox_config.recv_offset::16-little, mailbox_config.recv_size::16-little,
          mailbox_config.send_offset::16-little, mailbox_config.send_size::16-little>>
      )

    header <>
      sm_category(sm_entries) <>
      pdo_categories(pdo_entries) <>
      <<0xFFFF::16-little, 0::16-little>>
  end

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
        0::8,
        0::8,
        0::16-little,
        pdo_index::16-little,
        0::8,
        0::8,
        0::8,
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

  defp put_binary(binary, offset, value) do
    prefix = binary_part(binary, 0, offset)
    suffix_offset = offset + byte_size(value)
    suffix = binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
    prefix <> value <> suffix
  end
end
