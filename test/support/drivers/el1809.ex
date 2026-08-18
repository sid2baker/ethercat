defmodule EtherCAT.Driver.EL1809 do
  @moduledoc false

  @behaviour EtherCAT.Driver
  alias EtherCAT.Endpoint

  @vendor_id 0x0000_0002
  @product_code 0x0711_3052
  @channels [
    :ch1,
    :ch2,
    :ch3,
    :ch4,
    :ch5,
    :ch6,
    :ch7,
    :ch8,
    :ch9,
    :ch10,
    :ch11,
    :ch12,
    :ch13,
    :ch14,
    :ch15,
    :ch16
  ]

  def vendor_id, do: @vendor_id
  def product_code, do: @product_code

  @impl true
  def identity do
    %{vendor_id: @vendor_id, product_code: @product_code}
  end

  @impl true
  def signal_model(_config, _sii_pdo_configs) do
    [
      ch1: 0x1A00,
      ch2: 0x1A01,
      ch3: 0x1A02,
      ch4: 0x1A03,
      ch5: 0x1A04,
      ch6: 0x1A05,
      ch7: 0x1A06,
      ch8: 0x1A07,
      ch9: 0x1A08,
      ch10: 0x1A09,
      ch11: 0x1A0A,
      ch12: 0x1A0B,
      ch13: 0x1A0C,
      ch14: 0x1A0D,
      ch15: 0x1A0E,
      ch16: 0x1A0F
    ]
  end

  @impl true
  def encode_signal(_signal, _config, _value), do: <<>>

  @impl true
  def decode_signal(_signal, _config, <<_::7, bit::1>>), do: bit == 1
  def decode_signal(_signal, _config, _raw), do: false

  @impl true
  def describe(_config) do
    %{
      device_type: :digital_input,
      endpoints: Enum.map(@channels, &%Endpoint{signal: &1, direction: :input, type: :boolean})
    }
  end
end

defmodule EtherCAT.Driver.EL1809.Simulator do
  @moduledoc false

  @behaviour EtherCAT.Simulator.Adapter

  @impl true
  def definition_options(_config) do
    [
      profile: :digital_io,
      mode: :channels,
      direction: :input,
      channels: 16,
      serial_number: 0
    ]
  end
end
