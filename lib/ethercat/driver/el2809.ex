defmodule EtherCAT.Driver.EL2809 do
  @moduledoc "Beckhoff EL2809 16-channel digital output, 24 V DC."

  @behaviour EtherCAT.Driver
  @behaviour EtherCAT.Simulator.Driver

  @vendor_id 0x0000_0002
  @product_code 0x0AF9_3052
  @channels Enum.map(1..16, &String.to_atom("ch#{&1}"))

  def vendor_id, do: @vendor_id
  def product_code, do: @product_code

  @impl EtherCAT.Simulator.Driver
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
  def init(_config) do
    {:ok, initial_state()}
  end

  @impl true
  def describe(_config), do: %{device_type: :digital_output, capabilities: [:set_output]}

  @impl true
  def project_state(_decoded_inputs, prev_state, driver_state, _config)
      when is_map(driver_state) do
    {:ok, prev_state || Map.take(driver_state, @channels), driver_state, [], []}
  end

  @impl true
  def command(
        %{ref: ref, name: :set_output, args: %{signal: signal_name, value: value}},
        _state,
        driver_state,
        _config
      )
      when signal_name in @channels and is_boolean(value) do
    next_driver_state = Map.put(driver_state, signal_name, value)

    {:ok, [{:write, signal_name, value}], next_driver_state, [{:command_completed, ref}]}
  end

  def command(
        %{name: :set_output, args: %{signal: signal_name}},
        _state,
        _driver_state,
        _config
      )
      when signal_name in @channels,
      do: {:error, :invalid_output_value}

  def command(command, _state, _driver_state, _config),
    do: EtherCAT.Driver.unsupported_command(command)

  defp initial_state do
    Map.new(@channels, &{&1, false})
  end

  defp encode_bool(value) when value in [true, 1], do: 1
  defp encode_bool(_value), do: 0
end

defmodule EtherCAT.Driver.EL2809.Simulator do
  @moduledoc false

  @behaviour EtherCAT.Simulator.DriverAdapter

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
