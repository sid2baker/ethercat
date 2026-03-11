defmodule EtherCAT.IntegrationSupport.Drivers.EK1100 do
  @moduledoc false

  @behaviour EtherCAT.Slave.Driver

  @impl true
  def identity do
    %{vendor_id: 0x0000_0002, product_code: 0x044C_2C52}
  end

  @impl true
  def signal_model(_config), do: []

  @impl true
  def encode_signal(_signal, _config, _value), do: <<>>

  @impl true
  def decode_signal(_signal, _config, _raw), do: nil
end

defmodule EtherCAT.IntegrationSupport.Drivers.EK1100.Simulator do
  @moduledoc false

  @behaviour EtherCAT.Simulator.DriverAdapter

  @impl true
  def definition_options(_config) do
    [profile: :coupler, serial_number: 0]
  end
end
