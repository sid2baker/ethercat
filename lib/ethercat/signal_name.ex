defmodule EtherCAT.SignalName do
  @moduledoc false

  @max_pdo_index 0xFFFF
  @max_generated_signals 512
  @max_digital_channels 512

  @spec max_pdo_index() :: non_neg_integer()
  def max_pdo_index, do: @max_pdo_index

  @spec max_generated_signals() :: pos_integer()
  def max_generated_signals, do: @max_generated_signals

  @spec max_digital_channels() :: pos_integer()
  def max_digital_channels, do: @max_digital_channels

  @spec pdo_index?(term()) :: boolean()
  def pdo_index?(index), do: is_integer(index) and index >= 0 and index <= @max_pdo_index

  @spec pdo_name(non_neg_integer()) :: String.t()
  def pdo_name(index) do
    validate_pdo_index!(index)
    "pdo_0x" <> String.downcase(Integer.to_string(index, 16))
  end

  @spec direction_pdo_name(:input | :output, non_neg_integer()) :: String.t()
  def direction_pdo_name(direction, index) when direction in [:input, :output] do
    "#{direction}_" <> pdo_name(index)
  end

  @spec pdo_atom(non_neg_integer()) :: atom()
  def pdo_atom(index), do: pdo_name(index) |> :erlang.binary_to_atom(:utf8)

  @spec channel_atom(pos_integer()) :: atom()
  def channel_atom(index) do
    validate_digital_channel!(index)
    "ch#{index}" |> :erlang.binary_to_atom(:utf8)
  end

  @spec validate_generated_signal_count!(non_neg_integer(), term()) :: :ok
  def validate_generated_signal_count!(count, context)
      when is_integer(count) and count >= 0 and count <= @max_generated_signals do
    _ = context
    :ok
  end

  def validate_generated_signal_count!(count, context) do
    raise ArgumentError,
          "#{context} must include at most #{@max_generated_signals} generated signals, got: #{inspect(count)}"
  end

  @spec validate_pdo_index!(term(), term()) :: :ok
  def validate_pdo_index!(index, context \\ "PDO index")

  def validate_pdo_index!(index, _context) when is_integer(index) and index in 0..@max_pdo_index,
    do: :ok

  def validate_pdo_index!(index, context) do
    raise ArgumentError,
          "#{context} must be an integer in 0..#{@max_pdo_index}, got: #{inspect(index)}"
  end

  defp validate_digital_channel!(index)
       when is_integer(index) and index >= 1 and index <= @max_digital_channels do
    :ok
  end

  defp validate_digital_channel!(index) do
    raise ArgumentError,
          "digital channel index must be in 1..#{@max_digital_channels}, got: #{inspect(index)}"
  end
end
