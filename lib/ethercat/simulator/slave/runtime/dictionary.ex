defmodule EtherCAT.Simulator.Slave.Runtime.Dictionary do
  @moduledoc false

  alias EtherCAT.Simulator.Slave.Behaviour
  alias EtherCAT.Simulator.Slave.Object

  @spec inject_abort(map(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: map()
  def inject_abort(slave, index, subindex, abort_code) do
    %{
      slave
      | mailbox_abort_codes: Map.put(slave.mailbox_abort_codes, {index, subindex}, abort_code)
    }
  end

  @spec clear_aborts(map()) :: map()
  def clear_aborts(slave) do
    %{slave | mailbox_abort_codes: %{}}
  end

  @spec read_entry(map(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary(), map()} | {:error, non_neg_integer(), map()}
  def read_entry(slave, index, subindex) do
    case Map.fetch(slave.mailbox_abort_codes, {index, subindex}) do
      {:ok, abort_code} ->
        {:error, abort_code, slave}

      :error ->
        case Map.fetch(slave.objects, {index, subindex}) do
          {:ok, entry} ->
            case Behaviour.read_object(
                   slave.behavior,
                   index,
                   subindex,
                   entry,
                   slave,
                   slave.behavior_state
                 ) do
              {:ok, updated_entry, behavior_state} ->
                updated_slave =
                  slave
                  |> put_object(updated_entry)
                  |> Map.put(:behavior_state, behavior_state)

                case Object.encode(updated_entry, updated_slave.state) do
                  {:ok, binary} -> {:ok, binary, updated_slave}
                  {:error, abort_code} -> {:error, abort_code, updated_slave}
                end

              {:error, abort_code, behavior_state} ->
                {:error, abort_code, %{slave | behavior_state: behavior_state}}
            end

          :error ->
            {:error, Object.object_not_found_abort(), slave}
        end
    end
  end

  @spec write_entry(map(), non_neg_integer(), non_neg_integer(), binary()) ::
          {:ok, map()} | {:error, non_neg_integer(), map()}
  def write_entry(slave, index, subindex, binary) do
    case Map.fetch(slave.mailbox_abort_codes, {index, subindex}) do
      {:ok, abort_code} ->
        {:error, abort_code, slave}

      :error ->
        case Map.fetch(slave.objects, {index, subindex}) do
          {:ok, entry} ->
            with {:ok, entry} <- Object.decode(entry, slave.state, binary),
                 {:ok, entry, behavior_state} <-
                   Behaviour.write_object(
                     slave.behavior,
                     index,
                     subindex,
                     entry,
                     binary,
                     slave,
                     slave.behavior_state
                   ) do
              updated =
                slave
                |> put_object(entry)
                |> Map.put(:behavior_state, behavior_state)

              {:ok, updated}
            else
              {:error, abort_code} ->
                {:error, abort_code, slave}

              {:error, abort_code, behavior_state} ->
                {:error, abort_code, %{slave | behavior_state: behavior_state}}
            end

          :error ->
            {:error, Object.object_not_found_abort(), slave}
        end
    end
  end

  defp put_object(slave, %Object{} = entry) do
    %{slave | objects: Map.put(slave.objects, {entry.index, entry.subindex}, entry)}
  end
end
