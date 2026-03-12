defmodule EtherCAT.IntegrationSupport.Drivers.ConfiguredProcessMailboxDevice do
  @moduledoc false

  @behaviour EtherCAT.Slave.Driver

  alias EtherCAT.Slave.ProcessData.Signal

  @signals [
    led0: Signal.slice(0x1600, 0, 8),
    led1: Signal.slice(0x1600, 8, 8),
    button1: Signal.slice(0x1A00, 0, 8)
  ]

  @impl true
  def identity do
    %{vendor_id: 0x0000_0ACE, product_code: 0x0000_1602}
  end

  @impl true
  def signal_model(_config), do: @signals

  @impl true
  def mailbox_config(_config) do
    [{:sdo_download, 0x2003, 0x01, startup_blob()}]
  end

  @impl true
  def encode_signal(_signal, _config, value)
      when is_integer(value) and value >= 0 and value <= 255,
      do: <<value::8>>

  def encode_signal(_signal, _config, _value), do: <<>>

  @impl true
  def decode_signal(_signal, _config, <<value::8>>), do: value
  def decode_signal(_signal, _config, raw), do: raw

  def startup_blob do
    0..191
    |> Enum.map(fn value -> rem(value * 13 + 7, 256) end)
    |> :erlang.list_to_binary()
  end
end

defmodule EtherCAT.IntegrationSupport.Drivers.ConfiguredProcessMailboxDevice.Simulator do
  @moduledoc false

  @behaviour EtherCAT.Simulator.DriverAdapter

  @impl true
  def definition_options(_config) do
    [profile: :mailbox_device, revision: 0x0000_0001, serial_number: 0x0000_0002]
  end
end
