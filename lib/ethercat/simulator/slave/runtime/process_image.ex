defmodule EtherCAT.Simulator.Slave.Runtime.ProcessImage do
  @moduledoc false

  alias EtherCAT.Simulator.Slave.Behaviour
  alias EtherCAT.Simulator.Slave.Signals
  alias EtherCAT.Simulator.Slave.Value

  @spec output_image(map()) :: binary()
  def output_image(%{output_phys: output_phys, output_size: output_size} = slave) do
    read_register(slave, output_phys, output_size)
  end

  @spec signal_values(map()) :: %{optional(atom()) => term()}
  def signal_values(%{signals: signals} = slave) do
    Enum.reduce(signals, %{}, fn {signal_name, _definition}, acc ->
      case get_value(slave, signal_name) do
        {:ok, value} -> Map.put(acc, signal_name, value)
        {:error, _} -> acc
      end
    end)
  end

  @spec get_value(map(), atom()) :: {:ok, term()} | {:error, :unknown_signal}
  def get_value(%{signals: signals} = slave, signal_name) do
    case Signals.fetch(signals, signal_name) do
      {:ok, definition} ->
        image = signal_image(slave, definition.direction)
        {:ok, extract_value(image, definition)}

      :error ->
        {:error, :unknown_signal}
    end
  end

  @spec set_value(map(), atom(), term()) ::
          {:ok, map()} | {:error, :unknown_signal | :invalid_value}
  def set_value(%{signals: signals} = slave, signal_name, value) do
    case Signals.fetch(signals, signal_name) do
      {:ok, definition} ->
        set_signal_value(slave, signal_name, definition, value)

      :error ->
        {:error, :unknown_signal}
    end
  end

  @spec refresh_inputs(map()) :: map()
  def refresh_inputs(slave) do
    case Behaviour.refresh_inputs(slave.behavior, slave, slave.behavior_state) do
      {:ok, values, behavior_state} ->
        slave
        |> Map.put(:behavior_state, behavior_state)
        |> apply_behavior_inputs(values)
        |> apply_input_overrides()

      _ ->
        apply_input_overrides(slave)
    end
  end

  @spec write_register(map(), non_neg_integer(), binary()) :: map()
  def write_register(slave, offset, data) do
    old_output = output_image(slave)

    slave
    |> write_memory(offset, data)
    |> maybe_apply_output_side_effects(old_output)
  end

  defp set_signal_value(slave, _signal_name, %{direction: :output} = definition, value) do
    with {:ok, binary} <- Value.encode_binary(definition, value) do
      image = signal_image(slave, :output)
      updated = replace_value(image, definition, binary)

      updated_slave =
        slave
        |> write_memory(slave.output_phys, updated)
        |> maybe_apply_output_side_effects(image)

      {:ok, updated_slave}
    else
      {:error, _} -> {:error, :invalid_value}
    end
  end

  defp set_signal_value(slave, signal_name, %{direction: :input} = definition, value) do
    with {:ok, _binary} <- Value.encode_binary(definition, value) do
      updated_slave =
        slave
        |> put_input_override(signal_name, value)
        |> refresh_inputs()

      {:ok, updated_slave}
    else
      {:error, _} -> {:error, :invalid_value}
    end
  end

  defp maybe_apply_output_side_effects(slave, old_output) do
    new_output = output_image(slave)

    if old_output == new_output do
      slave
    else
      slave
      |> notify_output_changes(old_output, new_output)
      |> maybe_mirror_output(new_output)
      |> refresh_inputs()
    end
  end

  defp notify_output_changes(%{signals: signals} = slave, old_output, new_output) do
    Enum.reduce(signals, slave, fn {signal_name, definition}, current_slave ->
      if definition.direction == :output do
        old_value = extract_value(old_output, definition)
        new_value = extract_value(new_output, definition)

        if old_value != new_value do
          case Behaviour.handle_output_change(
                 current_slave.behavior,
                 signal_name,
                 new_value,
                 current_slave,
                 current_slave.behavior_state
               ) do
            {:ok, behavior_state} ->
              %{current_slave | behavior_state: behavior_state}

            {:error, _reason, behavior_state} ->
              %{current_slave | behavior_state: behavior_state}
          end
        else
          current_slave
        end
      else
        current_slave
      end
    end)
  end

  defp put_input_override(slave, signal_name, value) do
    %{slave | input_overrides: Map.put(slave.input_overrides, signal_name, value)}
  end

  defp apply_behavior_inputs(slave, values) when map_size(values) == 0, do: slave

  defp apply_behavior_inputs(slave, values) do
    Enum.reduce(values, slave, fn {signal_name, value}, current_slave ->
      case Signals.fetch(current_slave.signals, signal_name) do
        {:ok, %{direction: :input} = definition} ->
          case Value.encode_binary(definition, value) do
            {:ok, binary} ->
              image = signal_image(current_slave, :input)
              updated = replace_value(image, definition, binary)
              write_memory(current_slave, current_slave.input_phys, updated)

            {:error, _} ->
              current_slave
          end

        _ ->
          current_slave
      end
    end)
  end

  defp maybe_mirror_output(
         %{mirror_output_to_input?: true, input_phys: input_phys, input_size: input_size} = slave,
         bytes
       ) do
    mirrored =
      bytes
      |> binary_part(0, min(byte_size(bytes), input_size))
      |> Kernel.<>(:binary.copy(<<0>>, max(input_size - byte_size(bytes), 0)))

    write_memory(slave, input_phys, mirrored)
  end

  defp maybe_mirror_output(slave, _bytes), do: slave

  defp apply_input_overrides(%{input_overrides: overrides} = slave) when map_size(overrides) == 0,
    do: slave

  defp apply_input_overrides(slave) do
    Enum.reduce(slave.input_overrides, slave, fn {signal_name, value}, current_slave ->
      case Signals.fetch(current_slave.signals, signal_name) do
        {:ok, %{direction: :input} = definition} ->
          case Value.encode_binary(definition, value) do
            {:ok, binary} ->
              image = signal_image(current_slave, :input)
              updated = replace_value(image, definition, binary)
              write_memory(current_slave, current_slave.input_phys, updated)

            {:error, _} ->
              current_slave
          end

        :error ->
          current_slave
      end
    end)
  end

  defp signal_image(slave, :output), do: output_image(slave)

  defp signal_image(%{input_phys: input_phys, input_size: input_size} = slave, :input) do
    read_register(slave, input_phys, input_size)
  end

  defp extract_value(image, %{bit_offset: bit_offset, bit_size: bit_size} = definition)
       when rem(bit_offset, 8) == 0 and rem(bit_size, 8) == 0 do
    image
    |> binary_part(div(bit_offset, 8), div(bit_size, 8))
    |> then(&Value.decode_binary(definition, &1))
  end

  defp extract_value(image, %{bit_offset: bit_offset, bit_size: bit_size} = definition) do
    <<_prefix::bitstring-size(bit_offset), value::unsigned-integer-size(bit_size),
      _suffix::bitstring>> = image

    Value.decode_integer(definition, value)
  end

  defp replace_value(image, %{bit_offset: bit_offset, bit_size: bit_size}, binary)
       when rem(bit_offset, 8) == 0 and rem(bit_size, 8) == 0 do
    replace_binary(image, div(bit_offset, 8), binary)
  end

  defp replace_value(image, %{bit_offset: bit_offset, bit_size: bit_size} = definition, binary) do
    {:ok, value} = Value.encode_integer(definition, Value.decode_binary(definition, binary))

    <<prefix::bitstring-size(bit_offset), _current::bitstring-size(bit_size), suffix::bitstring>> =
      image

    <<prefix::bitstring, value::unsigned-integer-size(bit_size), suffix::bitstring>>
  end

  defp read_register(%{memory: memory}, offset, length) do
    binary_part(memory, offset, length)
  end

  defp write_memory(%{memory: memory} = slave, offset, data) do
    %{slave | memory: replace_binary(memory, offset, data)}
  end

  defp replace_binary(binary, offset, value) do
    prefix = binary_part(binary, 0, offset)
    suffix_offset = offset + byte_size(value)
    suffix = binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
    prefix <> value <> suffix
  end
end
