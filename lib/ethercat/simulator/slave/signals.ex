defmodule EtherCAT.Simulator.Slave.Signals do
  @moduledoc false

  alias EtherCAT.Slave.ProcessData.Signal
  alias EtherCAT.Simulator.Slave.Driver

  @type definition :: %{
          direction: :input | :output,
          pdo_index: non_neg_integer(),
          bit_offset: non_neg_integer(),
          bit_size: pos_integer()
        }

  @spec definitions(map()) :: %{optional(atom()) => definition()}
  def definitions(%{profile: profile, pdo_entries: pdo_entries}) do
    pdo_offsets = pdo_offsets(pdo_entries)

    profile
    |> driver_config()
    |> Driver.process_data_model()
    |> Enum.reduce(%{}, fn {signal_name, signal_spec}, acc ->
      case normalize_definition(signal_spec, pdo_offsets) do
        {:ok, definition} -> Map.put(acc, signal_name, definition)
        :skip -> acc
      end
    end)
  end

  @spec names(%{optional(atom()) => definition()}) :: [atom()]
  def names(definitions) do
    Map.keys(definitions)
  end

  @spec fetch(%{optional(atom()) => definition()}, atom()) :: {:ok, definition()} | :error
  def fetch(definitions, signal_name) do
    Map.fetch(definitions, signal_name)
  end

  defp pdo_offsets(pdo_entries) do
    {entries, _bits} =
      Enum.map_reduce(pdo_entries, %{input: 0, output: 0}, fn entry, offsets ->
        direction = entry.direction
        base_offset = Map.fetch!(offsets, direction)
        next_offsets = Map.put(offsets, direction, base_offset + entry.bit_size)

        {{entry.index,
          %{direction: direction, bit_offset: base_offset, bit_size: entry.bit_size}},
         next_offsets}
      end)

    Map.new(entries)
  end

  defp normalize_definition(%Signal{} = signal, pdo_offsets) do
    case Map.fetch(pdo_offsets, signal.pdo_index) do
      {:ok, base} ->
        {:ok,
         %{
           direction: base.direction,
           pdo_index: signal.pdo_index,
           bit_offset: base.bit_offset + signal.bit_offset,
           bit_size: signal.bit_size || base.bit_size
         }}

      :error ->
        :skip
    end
  end

  defp normalize_definition(pdo_index, pdo_offsets) when is_integer(pdo_index) do
    case Map.fetch(pdo_offsets, pdo_index) do
      {:ok, base} ->
        {:ok,
         %{
           direction: base.direction,
           pdo_index: pdo_index,
           bit_offset: base.bit_offset,
           bit_size: base.bit_size
         }}

      :error ->
        :skip
    end
  end

  defp driver_config(profile), do: %{profile: profile}
end
