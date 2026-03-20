defmodule EtherCAT.Driver.Default do
  @moduledoc false

  def signal_model(config), do: EtherCAT.Slave.DefaultDriver.signal_model(config, [])
  defdelegate signal_model(config, sii_pdo_configs), to: EtherCAT.Slave.DefaultDriver
  defdelegate encode_signal(signal_name, config, value), to: EtherCAT.Slave.DefaultDriver
  defdelegate decode_signal(signal_name, config, raw), to: EtherCAT.Slave.DefaultDriver

  defdelegate project_state(decoded_inputs, prev_state, driver_state, config),
    to: EtherCAT.Slave.DefaultDriver

  defdelegate command(command, projected_state, driver_state, config),
    to: EtherCAT.Slave.DefaultDriver
end
