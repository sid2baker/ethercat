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

  @impl true
  def init(opts) do
    {:ok,
     %{
       responses: Keyword.get(opts, :responses, []),
       info: Keyword.get(opts, :info),
       default_reply: Keyword.get(opts, :default_reply, @default_reply),
       calls_rev: []
     }}
  end

  @impl true
  def handle_call(
        {:transact, tx, _stale_after_us, _enqueued_at_us},
        _from,
        %{responses: [reply | rest], calls_rev: calls_rev} = state
      ) do
    {:reply, reply, %{state | responses: rest, calls_rev: [tx | calls_rev]}}
  end

  def handle_call(
        {:transact, tx, _stale_after_us, _enqueued_at_us},
        _from,
        %{default_reply: default_reply, calls_rev: calls_rev} = state
      ) do
    {:reply, default_reply, %{state | calls_rev: [tx | calls_rev]}}
  end

  def handle_call(:calls, _from, %{calls_rev: calls_rev} = state) do
    {:reply, Enum.reverse(calls_rev), state}
  end

  def handle_call(:info, _from, %{info: nil} = state) do
    {:reply, {:error, :unsupported}, state}
  end

  def handle_call(:info, _from, %{info: info} = state) do
    {:reply, {:ok, info}, state}
  end

  defp options_list?(opts) do
    Keyword.keyword?(opts) and
      Enum.all?(opts, fn {key, _value} -> key in @option_keys end)
  end
end
