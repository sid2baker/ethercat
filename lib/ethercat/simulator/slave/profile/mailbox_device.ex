defmodule EtherCAT.Simulator.Slave.Profile.MailboxDevice do
  @moduledoc false

  alias EtherCAT.Simulator.Slave.Object

  def spec(_opts) do
    %{
      profile: :mailbox_device,
      vendor_id: 0x0000_0ACE,
      product_code: 0x0000_1602,
      revision: 0x0000_0001,
      serial_number: 0x0000_0002,
      esc_type: 0x11,
      fmmu_count: 4,
      sm_count: 4,
      output_phys: 0x1100,
      output_size: 2,
      input_phys: 0x1180,
      input_size: 1,
      mirror_output_to_input?: true,
      mailbox_config: %{recv_offset: 0x1000, recv_size: 64, send_offset: 0x1040, send_size: 64},
      pdo_entries: [
        %{index: 0x1600, direction: :output, sm_index: 2, bit_size: 16},
        %{index: 0x1A00, direction: :input, sm_index: 3, bit_size: 8}
      ],
      objects: %{
        {0x2000, 0x01} =>
          Object.new(
            index: 0x2000,
            subindex: 0x01,
            name: :vendor_word,
            type: :u16,
            value: 0x1234,
            access: :rw,
            group: :config
          ),
        {0x2000, 0x02} =>
          Object.new(
            index: 0x2000,
            subindex: 0x02,
            name: :enable_flag,
            type: :u8,
            value: 0,
            access: :rw,
            group: :config
          ),
        {0x2001, 0x01} =>
          Object.new(
            index: 0x2001,
            subindex: 0x01,
            name: :blob,
            type: {:binary, 12},
            value: "hello-sim\0\0\0",
            access: :rw,
            group: :diagnostics
          ),
        {0x2002, 0x01} =>
          Object.new(
            index: 0x2002,
            subindex: 0x01,
            name: :segmented_blob,
            type: {:binary, 80},
            value: segmented_blob(),
            access: :rw,
            group: :diagnostics
          ),
        {0x2003, 0x01} =>
          Object.new(
            index: 0x2003,
            subindex: 0x01,
            name: :multi_segment_blob,
            type: {:binary, 192},
            value: multi_segment_blob(),
            access: :rw,
            group: :diagnostics
          )
      },
      dc_capable?: false,
      signals: signal_specs(),
      behavior: __MODULE__
    }
  end

  def signal_specs do
    %{
      led0: %{
        direction: :output,
        pdo_index: 0x1600,
        bit_offset: 0,
        bit_size: 8,
        type: :u8,
        label: "LED 0",
        group: :outputs
      },
      led1: %{
        direction: :output,
        pdo_index: 0x1600,
        bit_offset: 8,
        bit_size: 8,
        type: :u8,
        label: "LED 1",
        group: :outputs
      },
      button1: %{
        direction: :input,
        pdo_index: 0x1A00,
        bit_offset: 0,
        bit_size: 8,
        type: :u8,
        label: "Button 1",
        group: :inputs
      }
    }
  end

  def init(_definition), do: %{}

  defp segmented_blob do
    0..79
    |> Enum.to_list()
    |> :erlang.list_to_binary()
  end

  defp multi_segment_blob do
    0..191
    |> Enum.to_list()
    |> :erlang.list_to_binary()
  end
end
