defmodule EtherCAT.Driver.EL2809 do
  @moduledoc false

  @behaviour EtherCAT.Driver
  alias EtherCAT.Endpoint

  @vendor_id 0x0000_0002
  @product_code 0x0AF9_3052
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
      ch1: %EtherCAT.Driver.Signal{pdo_index: 0x1600},
      ch2: %EtherCAT.Driver.Signal{pdo_index: 0x1601},
      ch3: %EtherCAT.Driver.Signal{pdo_index: 0x1602},
      ch4: %EtherCAT.Driver.Signal{pdo_index: 0x1603},
      ch5: %EtherCAT.Driver.Signal{pdo_index: 0x1604},
      ch6: %EtherCAT.Driver.Signal{pdo_index: 0x1605},
      ch7: %EtherCAT.Driver.Signal{pdo_index: 0x1606},
      ch8: %EtherCAT.Driver.Signal{pdo_index: 0x1607},
      ch9: %EtherCAT.Driver.Signal{pdo_index: 0x1608},
      ch10: %EtherCAT.Driver.Signal{pdo_index: 0x1609},
      ch11: %EtherCAT.Driver.Signal{pdo_index: 0x160A},
      ch12: %EtherCAT.Driver.Signal{pdo_index: 0x160B},
      ch13: %EtherCAT.Driver.Signal{pdo_index: 0x160C},
      ch14: %EtherCAT.Driver.Signal{pdo_index: 0x160D},
      ch15: %EtherCAT.Driver.Signal{pdo_index: 0x160E},
      ch16: %EtherCAT.Driver.Signal{pdo_index: 0x160F}
    ]
  end

  @impl true
  def encode_signal(_signal, _config, value) when value in [true, 1], do: {:ok, <<1>>}
  def encode_signal(_signal, _config, value) when value in [false, 0], do: {:ok, <<0>>}
  def encode_signal(_signal, _config, _value), do: {:error, :invalid_value}

  @impl true
  def describe(_config) do
    %{
      device_type: :digital_output,
      endpoints: Enum.map(@channels, &%Endpoint{signal: &1, direction: :output, type: :boolean})
    }
  end
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
