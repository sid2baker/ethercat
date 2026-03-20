defmodule EtherCAT.IntegrationSupport.Drivers.EL1809 do
  @moduledoc false

  defdelegate identity(), to: EtherCAT.Driver.EL1809
  defdelegate signal_model(config, sii_pdo_configs), to: EtherCAT.Driver.EL1809
  defdelegate encode_signal(signal, config, value), to: EtherCAT.Driver.EL1809
  defdelegate decode_signal(signal, config, raw), to: EtherCAT.Driver.EL1809
  defdelegate init(config), to: EtherCAT.Driver.EL1809
  defdelegate describe(config), to: EtherCAT.Driver.EL1809

  defdelegate project_state(decoded_inputs, prev_state, driver_state, config),
    to: EtherCAT.Driver.EL1809

  defdelegate command(command, state, driver_state, config), to: EtherCAT.Driver.EL1809
end

defmodule EtherCAT.IntegrationSupport.Drivers.EL1809.Simulator do
  @moduledoc false

  defdelegate definition_options(config), to: EtherCAT.Driver.EL1809.Simulator
end
