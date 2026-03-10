defmodule EtherCAT.Support.Slave.Driver do
  @moduledoc false

  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_model(_config) do
    [out: 0x1600, in: 0x1A00]
  end

  @impl true
  def encode_signal(:out, _config, value) when is_integer(value) and value >= 0 and value <= 0xFF,
    do: <<value::8>>

  def encode_signal(:out, _config, true), do: <<1>>
  def encode_signal(:out, _config, false), do: <<0>>

  def encode_signal(:out, _config, value) when is_binary(value) and byte_size(value) == 1,
    do: value

  def encode_signal(_signal_name, _config, _value), do: <<0>>

  @impl true
  def decode_signal(:in, _config, <<value::8>>), do: value
  def decode_signal(:in, _config, _raw), do: 0
  def decode_signal(_signal_name, _config, _raw), do: nil
end
