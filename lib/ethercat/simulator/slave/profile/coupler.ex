defmodule EtherCAT.Simulator.Slave.Profile.Coupler do
  @moduledoc false

  def spec(_opts) do
    %{
      profile: :coupler,
      vendor_id: 0x0000_0ACE,
      product_code: 0x0000_1100,
      revision: 0x0000_0001,
      serial_number: 0x0000_0010,
      esc_type: 0x11,
      fmmu_count: 4,
      sm_count: 4,
      output_phys: 0x1100,
      output_size: 0,
      input_phys: 0x1180,
      input_size: 0,
      mirror_output_to_input?: false,
      pdo_entries: [],
      mailbox_config: %{recv_offset: 0, recv_size: 0, send_offset: 0, send_size: 0},
      objects: %{},
      dc_capable?: false,
      signals: signal_specs(),
      behavior: __MODULE__
    }
  end

  def signal_specs, do: %{}

  def init(_fixture), do: %{}
end
