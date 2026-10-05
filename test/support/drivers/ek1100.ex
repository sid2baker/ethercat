defmodule EtherCAT.Driver.EK1100 do
  @moduledoc false

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
  def describe(_config), do: %{device_type: :coupler, endpoints: []}
end

defmodule EtherCAT.Driver.EK1100.Simulator do
  @moduledoc false

  @behaviour EtherCAT.Simulator.Adapter

  @impl true
  def definition_options(_config) do
    [profile: :coupler, serial_number: 0]
  end
end
