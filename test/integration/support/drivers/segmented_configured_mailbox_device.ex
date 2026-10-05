defmodule EtherCAT.IntegrationSupport.Drivers.SegmentedConfiguredMailboxDevice do
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
    [{:sdo_download, 0x2003, 0x01, startup_blob()}]
  end

  def mailbox_steps(_config, _context), do: []

  def startup_blob do
    0..191
    |> Enum.map(fn value -> rem(value * 13 + 7, 256) end)
    |> :erlang.list_to_binary()
  end
end

defmodule EtherCAT.IntegrationSupport.Drivers.SegmentedConfiguredMailboxDevice.Simulator do
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
