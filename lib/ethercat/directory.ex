defmodule EtherCAT.Directory do
  @moduledoc """
  Minimal directory that maps `{device, signal}` pairs to values. Once domains
  are wired up the directory will point to domain-owned ETS tables. For now we
  simply keep everything in a :ets table managed by this module.
  """

  @type directory_ref :: :ets.tab()

  @spec build(list()) :: {:ok, directory_ref()} | {:error, term()}
  def build(devices) do
    table = :ets.new(__MODULE__, [:set, :protected])

    Enum.each(devices, fn %{name: device, driver: driver} ->
      driver.signals()
      |> Enum.each(fn %{name: signal, default: default} ->
        :ets.insert(table, {{device, signal}, default})
      end)
    end)

    {:ok, table}
  rescue
    e -> {:error, {:directory_failed, e}}
  end

  @spec fetch(directory_ref(), atom(), atom()) :: {:ok, term()} | {:error, term()}
  def fetch(nil, _device, _signal), do: {:error, :no_directory}

  def fetch(table, device, signal) do
    case :ets.lookup(table, {device, signal}) do
      [{_, value}] -> {:ok, value}
      [] -> {:error, :unknown_signal}
    end
  end
end
