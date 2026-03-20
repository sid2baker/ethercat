defmodule EtherCAT.IntegrationSupport.Drivers.EK1100 do
  @moduledoc false

  defdelegate identity(), to: EtherCAT.Driver.EK1100
  defdelegate signal_model(config, sii_pdo_configs), to: EtherCAT.Driver.EK1100
  defdelegate encode_signal(signal, config, value), to: EtherCAT.Driver.EK1100
  defdelegate decode_signal(signal, config, raw), to: EtherCAT.Driver.EK1100

  defdelegate project_state(decoded_inputs, prev_state, driver_state, config),
    to: EtherCAT.Driver.EK1100

  defdelegate command(command, state, driver_state, config), to: EtherCAT.Driver.EK1100
end

defmodule EtherCAT.IntegrationSupport.Drivers.EK1100.Simulator do
  @moduledoc false

  defdelegate definition_options(config), to: EtherCAT.Driver.EK1100.Simulator
end
