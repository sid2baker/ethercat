defmodule EtherCAT.IntegrationSupport.Drivers.ConfiguredProcessMailboxDevice do
  @moduledoc false

  @behaviour EtherCAT.Driver
  @behaviour EtherCAT.Driver.Provisioning

  alias EtherCAT.Driver.Signal

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
  def signal_model(_config, _sii_pdo_configs), do: @signals

  @impl true
  def mailbox_steps(_config, %{phase: :preop}) do
    [{:sdo_download, 0x2003, 0x01, startup_blob()}]
  end

  def mailbox_steps(_config, _context), do: []

  @impl true
  def encode_signal(_signal, _config, value)
      when is_integer(value) and value >= 0 and value <= 255,
      do: {:ok, <<value::8>>}

  def encode_signal(_signal, _config, _value), do: {:error, :invalid_value}

  @impl true
  def decode_signal(_signal, _config, <<value::8>>), do: {:ok, value}
  def decode_signal(_signal, _config, _raw), do: {:error, :invalid_data}

  def startup_blob do
    0..191
    |> Enum.map(fn value -> rem(value * 13 + 7, 256) end)
    |> :erlang.list_to_binary()
  end
end

defmodule EtherCAT.IntegrationSupport.Drivers.ConfiguredProcessMailboxDevice.Simulator do
  @moduledoc false

  @behaviour EtherCAT.Simulator.Adapter

  @impl true
  def definition_options(_config) do
    [profile: :mailbox_device, revision: 0x0000_0001, serial_number: 0x0000_0002]
  end
end
