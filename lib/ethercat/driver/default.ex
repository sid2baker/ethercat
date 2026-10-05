defmodule EtherCAT.Driver.Default do
  @moduledoc false

  @behaviour EtherCAT.Driver
  alias EtherCAT.SignalName

  @impl true
  def signal_model(_config, sii_pdo_configs) do
    sii_pdo_configs
    |> Enum.map(fn %{index: index} ->
      name = SignalName.pdo_atom(index)
      {name, %EtherCAT.Driver.Signal{pdo_index: index}}
    end)
  end

  @impl true
  def encode_signal(_signal_name, _config, value) when is_binary(value), do: {:ok, value}
  def encode_signal(_signal_name, _config, _value), do: {:error, :invalid_value}

  @impl true
  def decode_signal(_signal_name, _config, raw), do: {:ok, raw}
end
