defmodule EtherCAT.Driver.Default do
  @moduledoc false

  @behaviour EtherCAT.Driver

  def signal_model(config), do: signal_model(config, [])

  @impl true
  def signal_model(_config, sii_pdo_configs) do
    sii_pdo_configs
    |> Enum.map(fn %{index: index} ->
      name = String.to_atom("pdo_0x" <> String.downcase(Integer.to_string(index, 16)))
      {name, index}
    end)
  end

  @impl true
  def encode_signal(_signal_name, _config, value) when is_binary(value), do: value
  def encode_signal(_signal_name, _config, _value), do: <<>>

  @impl true
  def decode_signal(_signal_name, _config, raw), do: raw

  @impl true
  def project_state(decoded_inputs, _prev_state, driver_state, _config) do
    {:ok, decoded_inputs, driver_state, [], []}
  end

  @impl true
  def command(command, _projected_state, _driver_state, _config),
    do: EtherCAT.Driver.unsupported_command(command)
end
