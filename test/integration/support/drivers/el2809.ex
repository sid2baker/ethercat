defmodule EtherCAT.IntegrationSupport.Drivers.EL2809 do
  @moduledoc false

  @behaviour EtherCAT.Slave.Driver

  alias EtherCAT.Simulator.Slave.Definition

  @impl true
  def identity do
    %{vendor_id: 0x0000_0002, product_code: 0x0AF9_3052}
  end

  @impl true
  def simulator_definition(_config) do
    Definition.build(:digital_io,
      mode: :channels,
      direction: :output,
      channels: 16,
      vendor_id: 0x0000_0002,
      product_code: 0x0AF9_3052,
      serial_number: 0
    )
  end

  @channels 1..16
            |> Enum.map(fn channel ->
              {String.to_atom("ch#{channel}"), 0x1600 + (channel - 1)}
            end)

  @impl true
  def process_data_model(_config), do: @channels

  @impl true
  def encode_signal(_signal, _config, value), do: <<value::8>>

  @impl true
  def decode_signal(_signal, _config, _raw), do: nil
end
