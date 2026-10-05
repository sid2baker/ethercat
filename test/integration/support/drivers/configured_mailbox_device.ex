defmodule EtherCAT.IntegrationSupport.Drivers.ConfiguredMailboxDevice do
  @moduledoc false

  @behaviour EtherCAT.Driver
  @behaviour EtherCAT.Driver.Provisioning

  @impl true
  def identity do
    %{vendor_id: 0x0000_0ACE, product_code: 0x0000_1602}
  end

  @impl true
  def signal_model(_config, _sii_pdo_configs), do: []

  @impl true
  def mailbox_steps(_config, %{phase: :preop}) do
    [{:sdo_download, 0x2000, 0x02, <<1>>}]
  end

  def mailbox_steps(_config, _context), do: []
end

defmodule EtherCAT.IntegrationSupport.Drivers.ConfiguredMailboxDevice.Simulator do
  @moduledoc false

  @behaviour EtherCAT.Simulator.Adapter

  @impl true
  def definition_options(_config) do
    [
      profile: :mailbox_device,
      signals: %{},
      pdo_entries: [],
      output_size: 0,
      input_size: 0,
      mirror_output_to_input?: false,
      revision: 0x0000_0001,
      serial_number: 0x0000_0002
    ]
  end
end
