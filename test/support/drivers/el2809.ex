defmodule EtherCAT.Driver.EL2809 do
  @moduledoc false

  @behaviour EtherCAT.Driver
  alias EtherCAT.Endpoint

  @vendor_id 0x0000_0002
  @product_code 0x0AF9_3052
  @channels Enum.map(1..16, &String.to_atom("ch#{&1}"))

  def vendor_id, do: @vendor_id
  def product_code, do: @product_code

  @impl true
  def identity do
    %{vendor_id: @vendor_id, product_code: @product_code}
  end

  @impl true
  def signal_model(_config, _sii_pdo_configs) do
    [
      ch1: 0x1600,
      ch2: 0x1601,
      ch3: 0x1602,
      ch4: 0x1603,
      ch5: 0x1604,
      ch6: 0x1605,
      ch7: 0x1606,
      ch8: 0x1607,
      ch9: 0x1608,
      ch10: 0x1609,
      ch11: 0x160A,
      ch12: 0x160B,
      ch13: 0x160C,
      ch14: 0x160D,
      ch15: 0x160E,
      ch16: 0x160F
    ]
  end

  @impl true
  def encode_signal(_signal, _config, value), do: <<encode_bool(value)::8>>

  @impl true
  def decode_signal(_signal, _config, _raw), do: nil

  @impl true
  def describe(_config) do
    %{
      device_type: :digital_output,
      endpoints: Enum.map(@channels, &%Endpoint{signal: &1, direction: :output, type: :boolean})
    }
  end

  defp encode_bool(value) when value in [true, 1], do: 1
  defp encode_bool(_value), do: 0
end

defmodule EtherCAT.Driver.EL2809.Simulator do
  @moduledoc false

  @behaviour EtherCAT.Simulator.Adapter

  @impl true
  def definition_options(_config) do
    [
      profile: :digital_io,
      mode: :channels,
      direction: :output,
      channels: 16,
      serial_number: 0
    ]
  end
end
