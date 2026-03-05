defmodule EtherCAT.Slave.Driver.Default do
  @moduledoc """
  Fallback driver used when a slave is named without a specific hardware driver.

  This driver intentionally exposes no PDO profile. It allows a slave process
  to complete INIT→PREOP so hardware can be configured dynamically at runtime.
  """

  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile(_config), do: %{}

  @impl true
  def encode_outputs(_pdo_name, _config, _value), do: <<>>

  @impl true
  def decode_inputs(_pdo_name, _config, raw), do: raw
end
