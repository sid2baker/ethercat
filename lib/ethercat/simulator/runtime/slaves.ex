defmodule EtherCAT.Simulator.Runtime.Slaves do
  @moduledoc false

  @spec fetch([%{name: atom()}], atom()) :: {:ok, map()} | {:error, :not_found}
  def fetch(slaves, slave_name) do
    case Enum.find(slaves, &(&1.name == slave_name)) do
      nil -> {:error, :not_found}
      slave -> {:ok, slave}
    end
  end

  @spec update([%{name: atom()}], atom(), (map() -> map() | {:ok, map()} | {:error, term()})) ::
          {:ok, [map()]} | {:error, term()}
  def update(slaves, slave_name, fun) do
    {entries, matched?} =
      Enum.map_reduce(slaves, false, fn slave, matched? ->
        if slave.name == slave_name do
          {normalize_update(fun.(slave)), true}
        else
          {{:ok, slave}, matched?}
        end
      end)

    cond do
      not matched? ->
        {:error, :not_found}

      true ->
        case Enum.find(entries, &match?({:error, _}, &1)) do
          {:error, reason} ->
            {:error, reason}

          nil ->
            {:ok, Enum.map(entries, fn {:ok, slave} -> slave end)}
        end
    end
  end

  defp normalize_update({:ok, updated_slave}), do: {:ok, updated_slave}
  defp normalize_update({:error, reason}), do: {:error, reason}
  defp normalize_update(updated_slave), do: {:ok, updated_slave}
end
