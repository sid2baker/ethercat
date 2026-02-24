defmodule EtherCAT do
  @moduledoc """
  Public entrypoint for the EtherCAT master runtime.

  The implementation is currently scoped to the architectural skeleton: the
  transport layer behaves like a loopback device so developers can exercise the
  high level APIs while the low level AF_PACKET backend is being finalised.
  """

  alias EtherCAT.Master

  @type config :: map()
  @type bus_ref :: reference()

  @doc """
  Boots the bus using the provided configuration.
  """
  @spec start(config()) :: {:ok, bus_ref()} | {:error, term()}
  def start(config) when is_map(config) do
    Master.start(config)
  end

  @doc """
  Stops the active bus.
  """
  @spec stop(bus_ref()) :: :ok | {:error, term()}
  def stop(ref), do: Master.stop(ref)

  @doc """
  Reads the latest cached value for the given device/signal.
  """
  @spec read(bus_ref(), atom(), atom()) :: {:ok, term()} | {:error, term()}
  def read(ref, device, signal), do: Master.read(ref, device, signal)

  @doc """
  Queues a write for the given process data output.
  """
  @spec write(bus_ref(), atom(), atom(), term()) :: :ok | {:error, term()}
  def write(ref, device, signal, value), do: Master.write(ref, device, signal, value)

  @doc """
  Subscribes the calling process to signal change notifications.
  """
  @spec subscribe(bus_ref(), atom(), atom()) :: :ok | {:error, term()}
  def subscribe(ref, device, signal), do: Master.subscribe(ref, device, signal)

  @doc """
  Unsubscribes from change notifications.
  """
  @spec unsubscribe(bus_ref(), atom(), atom()) :: :ok
  def unsubscribe(ref, device, signal), do: Master.unsubscribe(ref, device, signal)

  @doc """
  Returns a snapshot describing the current bus status.
  """
  @spec status(bus_ref()) :: {:ok, map()} | {:error, term()}
  def status(ref), do: Master.status(ref)
end
