defmodule EtherCAT.Driver.EL1809 do
  @moduledoc "Beckhoff EL1809 16-channel digital input, 24 V DC."

  @behaviour EtherCAT.Driver

  @vendor_id 0x0000_0002
  @product_code 0x0711_3052
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
  def init(_config) do
    {:ok, initial_state()}
  end

  @impl true
  def describe(_config), do: %{device_type: :digital_input, capabilities: []}

  @impl true
  def project_state(decoded_inputs, prev_state, driver_state, _config) do
    next_state =
      prev_state
      |> Kernel.||(
        case driver_state do
          driver_state when is_map(driver_state) -> Map.take(driver_state, @channels)
          _ -> initial_state()
        end
      )
      |> Map.merge(Map.take(decoded_inputs, @channels))

    {:ok, next_state, driver_state, [], []}
  end

  @impl true
  def command(command, _state, _driver_state, _config),
    do: EtherCAT.Driver.unsupported_command(command)

  defp initial_state do
    Map.new(@channels, &{&1, false})
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
