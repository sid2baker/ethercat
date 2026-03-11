defmodule EtherCAT.Simulator.Slave.Runtime.Dictionary do
  @moduledoc false

  alias EtherCAT.Simulator.Slave.Behaviour
  alias EtherCAT.Simulator.Slave.Object

  @type abort_stage :: :request | :upload_segment | :download_segment

  @spec inject_abort(
          map(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          abort_stage()
        ) ::
          map()
  def inject_abort(slave, index, subindex, abort_code, stage)
      when stage in [:request, :upload_segment, :download_segment] do
    rule = %{index: index, subindex: subindex, abort_code: abort_code, stage: stage}
    %{slave | mailbox_abort_rules: upsert_abort_rule(slave.mailbox_abort_rules, rule)}
  end

  @spec clear_aborts(map()) :: map()
  def clear_aborts(slave) do
    %{slave | mailbox_abort_rules: []}
  end

  @spec abort_code(map(), non_neg_integer(), non_neg_integer(), abort_stage()) ::
          {:ok, non_neg_integer()} | :error
  def abort_code(slave, index, subindex, stage) do
    case Enum.find(slave.mailbox_abort_rules, &matches_abort_rule?(&1, index, subindex, stage)) do
      %{abort_code: abort_code} -> {:ok, abort_code}
      nil -> :error
    end
  end

  @spec read_entry(map(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary(), map()} | {:error, non_neg_integer(), map()}
  def read_entry(slave, index, subindex) do
    case abort_code(slave, index, subindex, :request) do
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
    case abort_code(slave, index, subindex, :request) do
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

  defp upsert_abort_rule(rules, %{index: index, subindex: subindex, stage: stage} = rule) do
    filtered =
      Enum.reject(rules, fn existing ->
        existing.index == index and existing.subindex == subindex and existing.stage == stage
      end)

    filtered ++ [rule]
  end

  defp matches_abort_rule?(rule, index, subindex, stage) do
    rule.index == index and rule.subindex == subindex and rule.stage == stage
  end
end
