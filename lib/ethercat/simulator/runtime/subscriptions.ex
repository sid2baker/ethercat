defmodule EtherCAT.Simulator.Runtime.Subscriptions do
  @moduledoc false

  @type subscription :: %{
          slave: atom(),
          signal: atom() | :all,
          pid: pid()
        }

  @type t :: %__MODULE__{
          subscriptions: [subscription()],
          monitors: %{optional(pid()) => reference()}
        }

  @enforce_keys [:subscriptions, :monitors]
  defstruct [:subscriptions, :monitors]

  @spec new() :: t()
  def new do
    %__MODULE__{subscriptions: [], monitors: %{}}
  end

  @spec info(t()) :: [map()]
  def info(%__MODULE__{} = state) do
    Enum.map(state.subscriptions, fn subscription ->
      %{slave: subscription.slave, signal: subscription.signal, pid: subscription.pid}
    end)
  end

  @spec subscribe(t(), [map()], atom(), atom() | :all, pid()) :: {:ok, t()} | {:error, :not_found}
  def subscribe(%__MODULE__{} = state, slaves, slave_name, signal_name, subscriber) do
    if Enum.any?(slaves, &(&1.name == slave_name)) do
      subscriptions =
        Enum.uniq_by(
          [%{slave: slave_name, signal: signal_name, pid: subscriber} | state.subscriptions],
          &{&1.slave, &1.signal, &1.pid}
        )

      monitors = ensure_monitor(state.monitors, subscriptions, subscriber)
      {:ok, %{state | subscriptions: subscriptions, monitors: monitors}}
    else
      {:error, :not_found}
    end
  end

  @spec unsubscribe(t(), [map()], atom(), atom() | :all, pid()) ::
          {:ok, t()} | {:error, :not_found}
  def unsubscribe(%__MODULE__{} = state, slaves, slave_name, signal_name, subscriber) do
    if Enum.any?(slaves, &(&1.name == slave_name)) do
      subscriptions =
        Enum.reject(state.subscriptions, fn subscription ->
          subscription.slave == slave_name and subscription.signal == signal_name and
            subscription.pid == subscriber
        end)

      monitors = maybe_demonitor(state.monitors, subscriptions, subscriber)
      {:ok, %{state | subscriptions: subscriptions, monitors: monitors}}
    else
      {:error, :not_found}
    end
  end

  @spec handle_down(t(), reference(), pid()) :: t()
  def handle_down(%__MODULE__{} = state, ref, pid) do
    case Map.fetch(state.monitors, pid) do
      {:ok, ^ref} ->
        subscriptions = Enum.reject(state.subscriptions, &(&1.pid == pid))
        monitors = Map.delete(state.monitors, pid)
        %{state | subscriptions: subscriptions, monitors: monitors}

      _ ->
        state
    end
  end

  @spec notify(t(), pid(), [{atom(), atom(), term()}]) :: :ok
  def notify(%__MODULE__{subscriptions: []}, _simulator, _changes), do: :ok

  def notify(%__MODULE__{subscriptions: subscriptions}, simulator, changes) do
    Enum.each(changes, fn {slave_name, signal_name, value} ->
      Enum.each(subscriptions, fn subscription ->
        if subscription.slave == slave_name and
             (subscription.signal == :all or subscription.signal == signal_name) do
          send(
            subscription.pid,
            {:ethercat_simulator, simulator, :signal_changed, slave_name, signal_name, value}
          )
        end
      end)
    end)

    :ok
  end

  defp ensure_monitor(monitors, subscriptions, pid) do
    if Map.has_key?(monitors, pid) or not Enum.any?(subscriptions, &(&1.pid == pid)) do
      monitors
    else
      Map.put(monitors, pid, Process.monitor(pid))
    end
  end

  defp maybe_demonitor(monitors, subscriptions, pid) do
    if Enum.any?(subscriptions, &(&1.pid == pid)) do
      monitors
    else
      case Map.pop(monitors, pid) do
        {nil, updated_monitors} ->
          updated_monitors

        {ref, updated_monitors} ->
          Process.demonitor(ref, [:flush])
          updated_monitors
      end
    end
  end
end
