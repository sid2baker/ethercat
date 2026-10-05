defmodule EtherCAT.Driver.Runtime do
  @moduledoc false

  alias EtherCAT.Driver
  alias EtherCAT.SlaveDescription
  alias EtherCAT.Driver.Signal

  @spec signal_model(module(), Driver.config(), [map()]) ::
          [{Driver.signal_name(), Signal.t()}]
  def signal_model(driver, config, sii_pdo_configs)
      when is_atom(driver) and is_map(config) and is_list(sii_pdo_configs) do
    pdos = Enum.map(sii_pdo_configs, &to_pdo/1)
    driver.signal_model(config, pdos)
  end

  defp to_pdo(%EtherCAT.Driver.PDO{} = pdo), do: pdo
  defp to_pdo(fields), do: struct!(EtherCAT.Driver.PDO, fields)

  @spec validate_codecs(module(), [map()]) :: :ok | {:error, term()}
  def validate_codecs(driver, groups) do
    groups
    |> Enum.map(& &1.direction)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn direction, :ok ->
      callback =
        case direction do
          :input -> :decode_signal
          :output -> :encode_signal
        end

      if function_exported?(driver, callback, 3),
        do: {:cont, :ok},
        else: {:halt, {:error, {:missing_driver_callback, callback, 3}}}
    end)
  end

  @spec encode(module(), atom(), map(), term(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def encode(driver, signal, config, value, bit_size) do
    with {:ok, encoded} <- driver.encode_signal(signal, config, value),
         :ok <- validate_encoding(encoded, bit_size) do
      {:ok, encoded}
    else
      {:error, reason} -> {:error, {:encode_failed, signal, reason}}
    end
  end

  @spec decode(module(), atom(), map(), binary()) :: {:ok, term()} | {:error, term()}
  def decode(driver, signal, config, raw) do
    case driver.decode_signal(signal, config, raw) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:decode_failed, signal, reason}}
    end
  end

  defp validate_encoding(encoded, bit_size) when is_binary(encoded) do
    expected_bytes = div(bit_size + 7, 8)

    if byte_size(encoded) == expected_bytes do
      padding = expected_bytes * 8 - bit_size

      <<_::binary-size(^expected_bytes - 1), high::size(^padding), _::size(8 - ^padding)>> =
        encoded

      if high == 0, do: :ok, else: {:error, :nonzero_padding}
    else
      {:error, {:invalid_encoded_size, expected_bytes, byte_size(encoded)}}
    end
  end

  @spec describe(module(), Driver.config()) :: Driver.description()
  def describe(driver, config) when is_atom(driver) and is_map(config) do
    SlaveDescription.native_description(driver, config)
  end

  @spec device_type(module(), Driver.config()) :: atom() | nil
  def device_type(driver, config) when is_atom(driver) and is_map(config) do
    describe(driver, config).device_type
  end

  @spec endpoints(module(), Driver.config()) :: [EtherCAT.Endpoint.t()]
  def endpoints(driver, config) when is_atom(driver) and is_map(config) do
    describe(driver, config).endpoints
  end
end
