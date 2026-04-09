defmodule EtherCAT.Simulator.Slave.Profile.AnalogIO do
  @moduledoc false

  use EtherCAT.Simulator.Slave.Behaviour

  alias EtherCAT.Simulator.Slave.Object

  def spec(_opts) do
    %{
      profile: :analog_io,
      vendor_id: 0x0000_0ACE,
      product_code: 0x0000_1701,
      revision: 0x0000_0001,
      serial_number: 0x0000_1001,
      esc_type: 0x11,
      fmmu_count: 4,
      sm_count: 4,
      output_phys: 0x1100,
      output_size: 2,
      input_phys: 0x1180,
      input_size: 2,
      mirror_output_to_input?: false,
      mailbox_config: %{recv_offset: 0x1000, recv_size: 64, send_offset: 0x1040, send_size: 64},
      pdo_entries: [
        %{index: 0x1600, direction: :output, sm_index: 2, bit_size: 16},
        %{index: 0x1A00, direction: :input, sm_index: 3, bit_size: 16}
      ],
      objects: %{
        {0x3000, 0x01} =>
          Object.new(
            index: 0x3000,
            subindex: 0x01,
            name: :analog_output,
            type: :i16,
            value: 0.0,
            access: :rw,
            scale: 0.1,
            unit: "V",
            group: :process
          ),
        {0x3100, 0x01} =>
          Object.new(
            index: 0x3100,
            subindex: 0x01,
            name: :analog_input,
            type: :i16,
            value: 0.0,
            access: :ro,
            scale: 0.1,
            unit: "V",
            group: :process
          )
      },
      dc_capable?: false,
      signals: signal_specs(),
      behavior: __MODULE__
    }
  end

  def signal_specs do
    %{
      ao0: %{
        direction: :output,
        pdo_index: 0x1600,
        bit_offset: 0,
        bit_size: 16,
        type: :i16,
        scale: 0.1,
        unit: "V",
        label: "Analog Output 0",
        group: :outputs
      },
      ai0: %{
        direction: :input,
        pdo_index: 0x1A00,
        bit_offset: 0,
        bit_size: 16,
        type: :i16,
        scale: 0.1,
        unit: "V",
        label: "Analog Input 0",
        group: :inputs
      }
    }
  end

  def init(_definition), do: %{analog_output: 0.0, analog_input: 0.0}

  def handle_output_change(:ao0, value, _device, state) do
    {:ok, %{state | analog_output: value, analog_input: value}}
  end

  def handle_output_change(_signal, _value, _device, state), do: {:ok, state}

  def refresh_inputs(_device, state) do
    {:ok, %{ai0: state.analog_input}, state}
  end
end
