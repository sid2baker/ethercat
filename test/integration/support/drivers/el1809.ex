defmodule EtherCAT.IntegrationSupport.Drivers.EL1809 do
  @moduledoc false

  @behaviour EtherCAT.Slave.Driver

  @impl true
  def identity do
    %{vendor_id: 0x0000_0002, product_code: 0x0711_3052}
  end

  @channels 1..16
            |> Enum.map(fn channel ->
              {String.to_atom("ch#{channel}"), 0x1A00 + (channel - 1)}
            end)

  @impl true
  def signal_model(_config), do: @channels

  @impl true
  def encode_signal(_signal, _config, _value), do: <<>>

  @impl true
  def decode_signal(_signal, _config, <<_::7, bit::1>>), do: bit

  def decode_signal(_signal, _config, _raw), do: 0
end

defmodule EtherCAT.IntegrationSupport.Drivers.EL1809.Simulator do
  @moduledoc false

  @behaviour EtherCAT.Simulator.DriverAdapter

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
