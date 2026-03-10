defmodule EtherCAT.Simulator.Runtime.Wiring do
  @moduledoc false

  alias EtherCAT.Simulator.Slave.Runtime.Device

  @type signal_ref :: {atom(), atom()}
  @type connection :: %{
          source: signal_ref(),
          target: signal_ref()
        }

  @spec capture_signal_values([Device.t()]) :: %{
          optional(atom()) => %{optional(atom()) => term()}
        }
  def capture_signal_values(slaves) do
    Map.new(slaves, fn slave -> {slave.name, Device.signal_values(slave)} end)
  end

  @spec connect([Device.t()], [connection()], signal_ref(), signal_ref()) ::
          {:ok, [connection()], [Device.t()]}
          | {:error, :not_found | :unknown_signal | :invalid_value}
  def connect(slaves, connections, {source_slave, source_signal}, {target_slave, target_signal}) do
    with :ok <- ensure_signal_exists(slaves, source_slave, source_signal),
         :ok <- ensure_signal_exists(slaves, target_slave, target_signal) do
      connections =
        Enum.uniq_by(
          [
            %{source: {source_slave, source_signal}, target: {target_slave, target_signal}}
            | connections
          ],
          &{&1.source, &1.target}
        )

      {:ok, connections,
       sync_connection(slaves, {source_slave, source_signal}, {target_slave, target_signal})}
    end
  end

  @spec disconnect([connection()], signal_ref(), signal_ref()) ::
          {:ok, [connection()]} | {:error, :not_found}
  def disconnect(connections, source, target) do
    updated_connections = Enum.reject(connections, &(&1.source == source and &1.target == target))

    if length(updated_connections) == length(connections) do
      {:error, :not_found}
    else
      {:ok, updated_connections}
    end
  end

  @spec settle(
          [Device.t()],
          [connection()],
          %{optional(atom()) => %{optional(atom()) => term()}},
          pos_integer()
        ) :: {[Device.t()], [{atom(), atom(), term()}]}
  def settle(slaves, connections, before_signals, limit \\ 32) do
    {settled_slaves, final_signals} =
      settle_connections(slaves, before_signals, connections, limit)

    {settled_slaves, signal_changes(before_signals, final_signals)}
  end

  defp ensure_signal_exists(slaves, slave_name, signal_name) do
    case Enum.find(slaves, &(&1.name == slave_name)) do
      nil ->
        {:error, :not_found}

      slave ->
        case Device.signal_definition(slave, signal_name) do
          {:ok, _definition} -> :ok
          :error -> {:error, :unknown_signal}
        end
    end
  end

  defp sync_connection(slaves, {source_slave, source_signal}, {target_slave, target_signal}) do
    case get_signal_value(slaves, source_slave, source_signal) do
      {:ok, value} ->
        case update_named_slave(slaves, target_slave, &Device.set_value(&1, target_signal, value)) do
          {:ok, updated_slaves} -> updated_slaves
          {:error, _reason} -> slaves
        end

      {:error, _reason} ->
        slaves
    end
  end

  defp settle_connections(slaves, _previous_signals, _connections, 0) do
    {slaves, capture_signal_values(slaves)}
  end

  defp settle_connections(slaves, _previous_signals, [], _remaining) do
    {slaves, capture_signal_values(slaves)}
  end

  defp settle_connections(slaves, previous_signals, connections, remaining) do
    current_signals = capture_signal_values(slaves)
    changes = signal_changes(previous_signals, current_signals)

    case propagate_connections(slaves, changes, connections) do
      {updated_slaves, false} ->
        {updated_slaves, current_signals}

      {updated_slaves, true} ->
        settle_connections(updated_slaves, current_signals, connections, remaining - 1)
    end
  end

  defp signal_changes(previous_signals, current_signals) do
    Enum.flat_map(current_signals, fn {slave_name, values} ->
      previous_values = Map.get(previous_signals, slave_name, %{})

      Enum.flat_map(values, fn {signal_name, value} ->
        if Map.get(previous_values, signal_name) != value do
          [{slave_name, signal_name, value}]
        else
          []
        end
      end)
    end)
  end

  defp propagate_connections(slaves, changes, connections) do
    Enum.reduce(changes, {slaves, false}, fn {source_slave, source_signal, value},
                                             {current_slaves, changed?} ->
      matching_connections =
        Enum.filter(connections, fn connection ->
          connection.source == {source_slave, source_signal}
        end)

      Enum.reduce(matching_connections, {current_slaves, changed?}, fn connection,
                                                                       {slaves_acc, any_changed?} ->
        {target_slave, target_signal} = connection.target
        before_target = get_signal_value(slaves_acc, target_slave, target_signal)

        case update_named_slave(
               slaves_acc,
               target_slave,
               &Device.set_value(&1, target_signal, value)
             ) do
          {:ok, updated_slaves} ->
            after_target = get_signal_value(updated_slaves, target_slave, target_signal)
            {updated_slaves, any_changed? or before_target != after_target}

          {:error, _reason} ->
            {slaves_acc, any_changed?}
        end
      end)
    end)
  end

  defp get_signal_value(slaves, slave_name, signal_name) do
    case Enum.find(slaves, &(&1.name == slave_name)) do
      nil -> {:error, :not_found}
      slave -> Device.get_value(slave, signal_name)
    end
  end

  defp update_named_slave(slaves, slave_name, fun) do
    {entries, matched?} =
      Enum.map_reduce(slaves, false, fn slave, matched? ->
        cond do
          slave.name == slave_name ->
            case fun.(slave) do
              {:ok, updated_slave} -> {{:ok, updated_slave}, true}
              {:error, reason} -> {{:error, reason}, true}
              updated_slave -> {{:ok, updated_slave}, true}
            end

          true ->
            {{:ok, slave}, matched?}
        end
      end)

    if matched? do
      case Enum.find(entries, &match?({:error, _}, &1)) do
        {:error, reason} ->
          {:error, reason}

        nil ->
          {:ok, Enum.map(entries, fn {:ok, slave} -> slave end)}
      end
    else
      {:error, :not_found}
    end
  end
end
