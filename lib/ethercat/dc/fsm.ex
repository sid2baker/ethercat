defmodule EtherCAT.DC.FSM do
  @moduledoc false

  @behaviour :gen_statem
  require Logger

  alias EtherCAT.DC
  alias EtherCAT.DC.Runtime
  alias EtherCAT.DC.State

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    :gen_statem.start_link({:local, DC}, __MODULE__, opts, [])
  end

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    Logger.metadata(component: :dc, ref_station: Keyword.fetch!(opts, :ref_station))
    {:ok, :running, State.new(opts)}
  end

  @impl true
  def handle_event(:enter, _old, :running, data) do
    {:keep_state_and_data, Runtime.enter_actions(data)}
  end

  def handle_event({:call, from}, :status, :running, data) do
    Runtime.status_reply(from, data)
  end

  def handle_event(:state_timeout, :tick, :running, data) do
    Runtime.handle_tick(data)
  end

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data
end
