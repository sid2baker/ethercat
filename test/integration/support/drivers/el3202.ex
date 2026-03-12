defmodule EtherCAT.IntegrationSupport.Drivers.EL3202 do
  @moduledoc false

  @behaviour EtherCAT.Slave.Driver

  @mailbox_steps [
    {:sdo_download, 0x8000, 0x19, <<8::16-little>>},
    {:sdo_download, 0x8010, 0x19, <<8::16-little>>}
  ]

  @impl true
  def identity do
    %{
      vendor_id: 0x0000_0002,
      product_code: 0x0C82_3052,
      revision: 0x0016_0000
    }
  end

  @signals [
    channel1: 0x1A00,
    channel2: 0x1A01
  ]

  @impl true
  def signal_model(_config), do: @signals

  @impl true
  def mailbox_config(_config), do: @mailbox_steps

  @impl true
  def encode_signal(_signal, _config, _value), do: <<>>

  @impl true
  def decode_signal(:channel1, _config, <<
        _::1,
        error::1,
        _::2,
        _::2,
        overrange::1,
        underrange::1,
        toggle::1,
        state::1,
        _::6,
        value::16-little
      >>) do
    %{
      ohms: value / 16.0,
      overrange: overrange == 1,
      underrange: underrange == 1,
      error: error == 1,
      invalid: state == 1,
      toggle: toggle
    }
  end

  def decode_signal(:channel2, _config, <<
        _::1,
        error::1,
        _::2,
        _::2,
        overrange::1,
        underrange::1,
        toggle::1,
        state::1,
        _::6,
        value::16-little
      >>) do
    %{
      ohms: value / 16.0,
      overrange: overrange == 1,
      underrange: underrange == 1,
      error: error == 1,
      invalid: state == 1,
      toggle: toggle
    }
  end

  def decode_signal(_signal, _config, _raw), do: nil
end

defmodule EtherCAT.IntegrationSupport.Drivers.EL3202.Simulator do
  @moduledoc false

  @behaviour EtherCAT.Simulator.DriverAdapter

  alias EtherCAT.Simulator.Slave.Object

  @impl true
  def definition_options(_config) do
    [
      profile: :mailbox_device,
      signals: %{
        channel1: %{
          label: "PDO 1a00",
          type: {:binary, 4},
          bit_size: 32,
          group: :inputs,
          direction: :input,
          bit_offset: 0,
          pdo_index: 6656
        },
        channel2: %{
          label: "PDO 1a01",
          type: {:binary, 4},
          bit_size: 32,
          group: :inputs,
          direction: :input,
          bit_offset: 32,
          pdo_index: 6657
        }
      },
      vendor_id: 2,
      product_code: 209_858_642,
      revision: 1_441_792,
      serial_number: 0,
      esc_type: 17,
      fmmu_count: 4,
      sm_count: 4,
      output_phys: 4352,
      output_size: 0,
      input_phys: 4480,
      input_size: 8,
      mirror_output_to_input?: false,
      mailbox_config: %{
        recv_offset: 4096,
        recv_size: 128,
        send_offset: 4224,
        send_size: 128
      },
      pdo_entries: [
        %{index: 6656, bit_size: 32, direction: :input, sm_index: 3},
        %{index: 6657, bit_size: 32, direction: :input, sm_index: 3}
      ],
      objects: %{
        {0x8000, 0x19} =>
          Object.new(
            index: 0x8000,
            subindex: 0x19,
            name: :channel1_element,
            type: {:binary, 2},
            value: <<8::16-little>>,
            access: :rw,
            group: :configuration
          ),
        {0x8010, 0x19} =>
          Object.new(
            index: 0x8010,
            subindex: 0x19,
            name: :channel2_element,
            type: {:binary, 2},
            value: <<8::16-little>>,
            access: :rw,
            group: :configuration
          )
      },
      dc_capable?: false
    ]
  end
end
