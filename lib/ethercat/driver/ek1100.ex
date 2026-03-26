defmodule EtherCAT.Driver.EK1100 do
  @moduledoc "Beckhoff EK1100 EtherCAT coupler."

  @behaviour EtherCAT.Driver

  @vendor_id 0x0000_0002
  @product_code 0x044C_2C52

  def vendor_id, do: @vendor_id
  def product_code, do: @product_code

  @impl true
  def identity do
    %{vendor_id: @vendor_id, product_code: @product_code}
  end

  @impl true
  def signal_model(_config, _sii_pdo_configs), do: []

  @impl true
  def encode_signal(_signal, _config, _value), do: <<>>

  @impl true
  def decode_signal(_signal, _config, _raw), do: nil

  @impl true
  def project_state(decoded_inputs, _prev_state, driver_state, _config) do
    {:ok, decoded_inputs, driver_state, [], []}
  end

  @impl true
  def command(command, _state, _driver_state, _config),
    do: EtherCAT.Driver.unsupported_command(command)
end

defmodule EtherCAT.Driver.EK1100.Simulator do
  @moduledoc false

  @behaviour EtherCAT.Simulator.Adapter

  @impl true
  def definition_options(_config) do
    [profile: :coupler, serial_number: 0]
  end
end
