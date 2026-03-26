defmodule EtherCAT.IntegrationSupport.Drivers.MailboxDevice do
  @moduledoc false

  @behaviour EtherCAT.Driver

  @impl true
  def identity do
    %{vendor_id: 0x0000_0ACE, product_code: 0x0000_1602}
  end

  @impl true
  def signal_model(_config, _sii_pdo_configs), do: []

  @impl true
  def encode_signal(_signal, _config, value) when is_binary(value), do: value
  def encode_signal(_signal, _config, _value), do: <<>>

  @impl true
  def decode_signal(_signal, _config, raw), do: raw

  @impl true
  def project_state(decoded_inputs, _prev_state, driver_state, _config) do
    {:ok, decoded_inputs, driver_state, [], []}
  end

  @impl true
  def command(command, _state, _driver_state, _config),
    do: EtherCAT.Driver.unsupported_command(command)
end

defmodule EtherCAT.IntegrationSupport.Drivers.MailboxDevice.Simulator do
  @moduledoc false

  @behaviour EtherCAT.Simulator.Adapter

  @impl true
  def definition_options(_config) do
    [profile: :mailbox_device, revision: 0x0000_0001, serial_number: 0x0000_0002]
  end
end
