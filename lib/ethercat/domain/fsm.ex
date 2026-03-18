defmodule EtherCAT.Domain.FSM do
  @moduledoc false

  @behaviour :gen_statem
  require Logger

  alias EtherCAT.Domain.Calls
  alias EtherCAT.Domain.Cycle
  alias EtherCAT.Domain.State

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    Logger.metadata(component: :domain, domain: Keyword.fetch!(opts, :id))
    {:ok, :open, State.new(opts)}
  end

  @impl true
  def handle_event(:enter, _old, :open, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :cycling, data),
    do: {:keep_state_and_data, Cycle.enter_actions(data)}

  def handle_event(:enter, _old, :stopped, _data), do: :keep_state_and_data

  def handle_event({:call, from}, {:register_pdo, key, size, direction}, :open, data) do
    Calls.register_pdo(from, key, size, direction, data)
  end

  def handle_event({:call, from}, {:register_pdo, _, _, _}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_open}}]}
  end

  def handle_event({:call, from}, :start_cycling, state, data)
      when state in [:open, :stopped, :cycling],
      do: Calls.start_cycling(from, state, data)

  def handle_event({:call, from}, :stop_cycling, state, data)
      when state in [:open, :stopped, :cycling],
      do: Calls.stop_cycling(from, state, data)

  def handle_event(:state_timeout, :tick, :cycling, data), do: Cycle.handle_tick(data)

  def handle_event({:call, from}, :stats, state, data) do
    Calls.stats(from, state, data)
  end

  def handle_event({:call, from}, :info, state, data) do
    Calls.info(from, state, data)
  end

  def handle_event({:call, from}, {:update_cycle_time, new_us}, _state, data) do
    Calls.update_cycle_time(from, new_us, data)
  end

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data
end
