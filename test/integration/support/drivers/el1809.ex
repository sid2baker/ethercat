defmodule EtherCAT.IntegrationSupport.Drivers.EL1809 do
  @moduledoc false

  @behaviour EtherCAT.Slave.Driver

  @impl true
  def identity, do: nil

  @impl true
  def simulator_definition(_config), do: nil

  @channels 1..16
            |> Enum.map(fn channel ->
              {String.to_atom("ch#{channel}"), 0x1A00 + (channel - 1)}
            end)

  @impl true
  def process_data_model(_config), do: @channels

  @impl true
  def encode_signal(_signal, _config, _value), do: <<>>

  @impl true
  def decode_signal(_signal, _config, <<_::7, bit::1>>), do: bit

  def decode_signal(_signal, _config, _raw), do: 0
end
