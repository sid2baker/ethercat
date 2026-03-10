defmodule EtherCAT.Simulator.Slave.Profile.TemperatureInput do
  @moduledoc false

  alias EtherCAT.Simulator.Slave.Object

  def spec(_opts) do
    %{
      profile: :temperature_input,
      vendor_id: 0x0000_0ACE,
      product_code: 0x0000_1801,
      revision: 0x0000_0001,
      serial_number: 0x0000_1002,
      esc_type: 0x11,
      fmmu_count: 4,
      sm_count: 4,
      output_phys: 0x1100,
      output_size: 0,
      input_phys: 0x1180,
      input_size: 3,
      mirror_output_to_input?: false,
      mailbox_config: %{recv_offset: 0x1000, recv_size: 64, send_offset: 0x1040, send_size: 64},
      pdo_entries: [
        %{index: 0x1A00, direction: :input, sm_index: 3, bit_size: 24}
      ],
      objects: %{
        {0x6000, 0x01} =>
          Object.new(
            index: 0x6000,
            subindex: 0x01,
            name: :temperature,
            type: :i16,
            value: 25.0,
            access: :ro,
            scale: 0.1,
            unit: "C",
            group: :process
          ),
        {0x6000, 0x02} =>
          Object.new(
            index: 0x6000,
            subindex: 0x02,
            name: :status,
            type: :u8,
            value: 0,
            access: :ro,
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
      temp0: %{
        direction: :input,
        pdo_index: 0x1A00,
        bit_offset: 0,
        bit_size: 16,
        type: :i16,
        scale: 0.1,
        unit: "C",
        label: "Temperature 0",
        group: :inputs
      },
      status: %{
        direction: :input,
        pdo_index: 0x1A00,
        bit_offset: 16,
        bit_size: 8,
        type: :u8,
        label: "Status",
        group: :diagnostics
      }
    }
  end

  def init(_fixture), do: %{temperature: 25.0, status: 0}

  def refresh_inputs(_device, state) do
    {:ok, %{temp0: state.temperature, status: state.status}, state}
  end
end
