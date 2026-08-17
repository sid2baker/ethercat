defmodule EtherCAT.Driver.Default do
  @moduledoc false

  @behaviour EtherCAT.Driver
  alias EtherCAT.SignalName

  def signal_model(config), do: signal_model(config, [])

  @impl true
  def signal_model(_config, sii_pdo_configs) do
    sii_pdo_configs
    |> Enum.map(fn %{index: index} ->
      name = SignalName.pdo_atom(index)
      {name, index}
    end)
  end

  @impl true
  def encode_signal(_signal_name, _config, value) when is_binary(value), do: value
  def encode_signal(_signal_name, _config, _value), do: <<>>

  @impl true
  def decode_signal(_signal_name, _config, raw), do: raw
end
