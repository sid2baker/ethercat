defmodule EtherCAT.Slave.Runtime.State do
  @moduledoc false

  alias EtherCAT.Slave

  @spec new(keyword()) :: %Slave{}
  def new(opts) do
    %Slave{
      bus: Keyword.fetch!(opts, :bus),
      position: Keyword.get(opts, :position, 0),
      station: Keyword.fetch!(opts, :station),
      name: Keyword.fetch!(opts, :name),
      driver: Keyword.get(opts, :driver, EtherCAT.Slave.Driver.Default),
      config: Keyword.get(opts, :config, %{}),
      configuration_error: nil,
      esc_info: nil,
      dc_cycle_ns: Keyword.get(opts, :dc_cycle_ns),
      sync_config: Keyword.get(opts, :sync),
      mailbox_counter: 0,
      sii_sm_configs: [],
      sii_pdo_configs: [],
      process_data_request: Keyword.get(opts, :process_data, :none),
      latch_names: %{},
      active_latches: nil,
      latch_poll_ms: nil,
      health_poll_ms:
        Keyword.get(opts, :health_poll_ms, EtherCAT.Slave.Config.default_health_poll_ms()),
      startup_retry_phase: nil,
      startup_retry_count: 0,
      signal_registrations: %{},
      signal_registrations_by_sm: %{},
      output_domain_ids_by_sm: %{},
      output_sm_images: %{},
      subscriptions: %{},
      subscriber_refs: %{}
    }
  end
end
