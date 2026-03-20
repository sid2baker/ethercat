defmodule EtherCAT.Simulator.Slave.Driver do
  @moduledoc false

  @behaviour EtherCAT.Driver

  alias EtherCAT.Slave.ProcessData.Signal
  alias EtherCAT.Simulator.Slave.Profile
  alias EtherCAT.Simulator.Slave.Value

  @impl true
  def signal_model(config, _sii_pdo_configs) do
    profile = profile(config)

    signal_specs = Profile.signal_specs(profile)

    counts =
      signal_specs
      |> Enum.group_by(fn {_name, definition} -> definition.pdo_index end)
      |> Map.new(fn {pdo_index, entries} -> {pdo_index, length(entries)} end)

    signal_specs
    |> Enum.reduce([], fn {signal_name, definition}, acc ->
      single_signal_pdo? = Map.fetch!(counts, definition.pdo_index) == 1

      signal =
        case definition do
          %{bit_offset: 0, bit_size: bit_size, pdo_index: pdo_index}
          when rem(bit_size, 8) == 0 and single_signal_pdo? ->
            {signal_name, pdo_index}

          %{pdo_index: pdo_index, bit_offset: bit_offset, bit_size: bit_size} ->
            {signal_name, Signal.slice(pdo_index, bit_offset, bit_size)}
        end

      [signal | acc]
    end)
    |> Enum.reverse()
  end

  @impl true
  def encode_signal(signal_name, config, value) do
    config
    |> profile()
    |> Profile.signal_specs()
    |> Map.fetch(signal_name)
    |> case do
      {:ok, definition} ->
        case Value.encode_binary(definition, value) do
          {:ok, binary} -> binary
          {:error, _} -> zero_bytes(definition)
        end

      :error ->
        <<0>>
    end
  end

  @impl true
  def decode_signal(signal_name, config, raw) do
    config
    |> profile()
    |> Profile.signal_specs()
    |> Map.fetch(signal_name)
    |> case do
      {:ok, definition} -> Value.decode_binary(definition, raw)
      :error -> nil
    end
  end

  @impl true
  def project_state(decoded_inputs, _prev_state, driver_state, _config) do
    {:ok, decoded_inputs, driver_state, [], []}
  end

  @impl true
  def command(command, _state, _driver_state, _config),
    do: EtherCAT.Driver.unsupported_command(command)

  defp zero_bytes(definition) do
    :binary.copy(<<0>>, div(definition.bit_size, 8))
  end

  defp profile(%{profile: profile}), do: profile
  defp profile(_config), do: :digital_io
end
