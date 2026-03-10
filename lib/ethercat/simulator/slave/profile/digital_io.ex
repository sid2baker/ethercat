defmodule EtherCAT.Simulator.Slave.Profile.DigitalIO do
  @moduledoc false

  def spec(_opts) do
    %{
      profile: :digital_io,
      vendor_id: 0x0000_0ACE,
      product_code: 0x0000_1601,
      revision: 0x0000_0001,
      serial_number: 0x0000_0001,
      esc_type: 0x11,
      fmmu_count: 4,
      sm_count: 4,
      output_phys: 0x1100,
      output_size: 1,
      input_phys: 0x1180,
      input_size: 1,
      mirror_output_to_input?: true,
      pdo_entries: [
        %{index: 0x1600, direction: :output, sm_index: 2, bit_size: 8},
        %{index: 0x1A00, direction: :input, sm_index: 3, bit_size: 8}
      ],
      mailbox_config: %{recv_offset: 0, recv_size: 0, send_offset: 0, send_size: 0},
      objects: %{},
      dc_capable?: false,
      signals: signal_specs(),
      behavior: __MODULE__
    }
  end

  def signal_specs do
    %{
      out: %{
        direction: :output,
        pdo_index: 0x1600,
        bit_offset: 0,
        bit_size: 8,
        type: :u8,
        label: "Output",
        group: :outputs
      },
      in: %{
        direction: :input,
        pdo_index: 0x1A00,
        bit_offset: 0,
        bit_size: 8,
        type: :u8,
        label: "Input",
        group: :inputs
      }
    }
  end

  def init(_definition), do: %{}
end
