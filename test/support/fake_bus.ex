defmodule EtherCAT.TestSupport.FakeBus do
  @moduledoc false

  use GenServer

  @default_reply {:ok, [%{data: <<0>>, wkc: 1, circular: false, irq: 0}]}
  @option_keys [:responses, :info, :name, :default_reply]

  def start_link(opts) when is_list(opts) do
    opts =
      if options_list?(opts) do
        opts
      else
        [responses: opts]
      end

    start_opts =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  def calls(server) do
    GenServer.call(server, :calls)
  end

  def stale_after_us(server) do
    GenServer.call(server, :stale_after_us)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       responses: Keyword.get(opts, :responses, []),
       info: Keyword.get(opts, :info),
       default_reply: Keyword.get(opts, :default_reply, @default_reply),
       calls_rev: [],
       stale_after_us_rev: []
     }}
  end

  @impl true
  def handle_call(
        {:transact, tx, stale_after_us, _enqueued_at_us},
        from,
        %{responses: [{:delay, delay_ms, reply} | rest]} = state
      ) do
    Process.send_after(self(), {:delayed_reply, from, reply}, delay_ms)
    {:noreply, record_call(%{state | responses: rest}, tx, stale_after_us)}
  end

  def handle_call(
        {:transact, tx, stale_after_us, _enqueued_at_us},
        _from,
        %{responses: [reply | rest]} = state
      ) do
    {:reply, reply, record_call(%{state | responses: rest}, tx, stale_after_us)}
  end

  def handle_call(
        {:transact, tx, stale_after_us, _enqueued_at_us},
        _from,
        %{default_reply: default_reply} = state
      ) do
    {:reply, default_reply, record_call(state, tx, stale_after_us)}
  end

  def handle_call(:calls, _from, %{calls_rev: calls_rev} = state) do
    {:reply, Enum.reverse(calls_rev), state}
  end

  def handle_call(:stale_after_us, _from, %{stale_after_us_rev: deadlines} = state) do
    {:reply, Enum.reverse(deadlines), state}
  end

  def handle_call(:settle, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:set_frame_timeout, _timeout_ms}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:info, _from, %{info: nil} = state) do
    {:reply, {:error, :unsupported}, state}
  end

  def handle_call(:info, _from, %{info: info} = state) do
    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_info({:delayed_reply, from, reply}, state) do
    GenServer.reply(from, reply)
    {:noreply, state}
  end

  defp record_call(state, tx, stale_after_us) do
    %{
      state
      | calls_rev: [tx | state.calls_rev],
        stale_after_us_rev: [stale_after_us | state.stale_after_us_rev]
    }
  end

  defp options_list?(opts) do
    Keyword.keyword?(opts) and
      Enum.all?(opts, fn {key, _value} -> key in @option_keys end)
  end
end
