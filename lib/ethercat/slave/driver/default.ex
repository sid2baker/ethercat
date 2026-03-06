defmodule EtherCAT.Slave.Driver.Default do
  @moduledoc """
  Fallback driver used when a slave is named without a specific hardware driver.

  When used with `process_data: {:all, domain_id}`, this driver auto-discovers
  all PDOs declared in SII EEPROM and registers one signal per PDO. Signal names
  are derived from the PDO index: `0x1A00` → `:pdo_0x1a00`.

  Raw bytes are passed through unchanged for both encode and decode, so
  `read_input/2` returns a binary and `write_output/2` accepts a binary.
  """

  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_model(_config), do: %{}

  @impl true
  def process_data_model(_config, sii_pdo_configs) do
    Enum.reduce(sii_pdo_configs, %{}, fn %{index: index}, acc ->
      name = String.to_atom("pdo_0x" <> String.downcase(Integer.to_string(index, 16)))
      Map.put(acc, name, index)
    end)
  end

  @impl true
  def encode_signal(_signal_name, _config, value) when is_binary(value), do: value
  def encode_signal(_signal_name, _config, _value), do: <<>>

  @impl true
  def decode_signal(_signal_name, _config, raw), do: raw
end
