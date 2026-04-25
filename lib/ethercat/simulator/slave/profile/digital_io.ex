defmodule EtherCAT.Simulator.Slave.Profile.DigitalIO do
  @moduledoc false

  use EtherCAT.Simulator.Slave.Behaviour

  @default_output_pdo 0x1600
  @default_input_pdo 0x1A00

  def spec(opts) do
    mode = Keyword.get(opts, :mode, :image)
    channel_count = Keyword.get(opts, :channels, 8)
    direction = Keyword.get(opts, :direction, :io)

    {pdo_entries, signals, output_size, input_size, mirror_output_to_input?} =
      case mode do
        :channels ->
          channel_layout(direction, channel_count, opts)

        :image ->
          {image_pdo_entries(), image_signal_specs(), 1, 1, true}
      end

    %{
      profile: :digital_io,
      vendor_id: Keyword.get(opts, :vendor_id, 0x0000_0ACE),
      product_code: Keyword.get(opts, :product_code, 0x0000_1601),
      revision: Keyword.get(opts, :revision, 0x0000_0001),
      serial_number: Keyword.get(opts, :serial_number, 0x0000_0001),
      esc_type: Keyword.get(opts, :esc_type, 0x11),
      fmmu_count: Keyword.get(opts, :fmmu_count, 4),
      sm_count: Keyword.get(opts, :sm_count, 4),
      output_phys: 0x1100,
      output_size: output_size,
      input_phys: 0x1180,
      input_size: input_size,
      mirror_output_to_input?: mirror_output_to_input?,
      pdo_entries: pdo_entries,
      mailbox_config: %{recv_offset: 0, recv_size: 0, send_offset: 0, send_size: 0},
      objects: %{},
      dc_capable?: false,
      signals: signals,
      behavior: __MODULE__
    }
  end

  def channel_signal_specs(direction, channel_count, opts \\ []) do
    channel_layout(direction, channel_count, opts)
    |> elem(1)
  end

  def pdo_entries(direction, channel_count, opts \\ []) do
    channel_layout(direction, channel_count, opts)
    |> elem(0)
  end

  def signal_specs, do: image_signal_specs()

  defp image_signal_specs do
    %{
      out: %{
        direction: :output,
        pdo_index: @default_output_pdo,
        bit_offset: 0,
        bit_size: 8,
        type: :u8,
        label: "Output",
        group: :outputs
      },
      in: %{
        direction: :input,
        pdo_index: @default_input_pdo,
        bit_offset: 0,
        bit_size: 8,
        type: :u8,
        label: "Input",
        group: :inputs
      }
    }
  end

  defp image_pdo_entries do
    [
      %{index: @default_output_pdo, direction: :output, sm_index: 2, bit_size: 8},
      %{index: @default_input_pdo, direction: :input, sm_index: 3, bit_size: 8}
    ]
  end

  defp channel_layout(direction, channel_count, opts)
       when direction in [:input, :output, :io] and is_integer(channel_count) and
              channel_count > 0 do
    default_channel_names = default_names(channel_count)
    input_names = Keyword.get(opts, :input_names, default_channel_names)
    output_names = Keyword.get(opts, :output_names, default_channel_names)
    input_pdo_base = Keyword.get(opts, :input_pdo_base, @default_input_pdo)
    output_pdo_base = Keyword.get(opts, :output_pdo_base, @default_output_pdo)

    input_signals = build_channel_signals(:input, input_names, input_pdo_base)
    output_signals = build_channel_signals(:output, output_names, output_pdo_base)

    {pdo_entries, signals, output_size, input_size} =
      case direction do
        :input ->
          {build_channel_pdos(:input, input_pdo_base, input_names), input_signals, 0,
           bit_bytes(length(input_names))}

        :output ->
          {build_channel_pdos(:output, output_pdo_base, output_names), output_signals,
           bit_bytes(length(output_names)), 0}

        :io ->
          {build_channel_pdos(:output, output_pdo_base, output_names) ++
             build_channel_pdos(:input, input_pdo_base, input_names),
           Map.merge(output_signals, input_signals), bit_bytes(length(output_names)),
           bit_bytes(length(input_names))}
      end

    mirror_output_to_input? =
      direction == :io and Keyword.get(opts, :mirror_output_to_input?, true)

    {pdo_entries, signals, output_size, input_size, mirror_output_to_input?}
  end

  defp build_channel_pdos(direction, base, names) do
    sm_index =
      case direction do
        :output -> 2
        :input -> 3
      end

    names
    |> Enum.with_index()
    |> Enum.map(fn {_name, index} ->
      %{index: base + index, direction: direction, sm_index: sm_index, bit_size: 1}
    end)
  end

  defp build_channel_signals(direction, names, pdo_base) do
    names
    |> Enum.with_index()
    |> Enum.into(%{}, fn {name, index} ->
      {name,
       %{
         direction: direction,
         pdo_index: pdo_base + index,
         bit_offset: lsb_first_bit_offset(index),
         bit_size: 1,
         type: :bool,
         label: default_label(direction, index + 1),
         group: default_group(direction)
       }}
    end)
  end

  defp default_names(channel_count) do
    Enum.map(1..channel_count, &String.to_atom("ch#{&1}"))
  end

  defp default_label(:input, channel), do: "Input #{channel}"
  defp default_label(:output, channel), do: "Output #{channel}"

  defp default_group(:input), do: :inputs
  defp default_group(:output), do: :outputs

  defp bit_bytes(bit_count) do
    div(bit_count + 7, 8)
  end

  defp lsb_first_bit_offset(index) do
    div(index, 8) * 8 + (7 - rem(index, 8))
  end

  def init(_definition), do: %{}
end
