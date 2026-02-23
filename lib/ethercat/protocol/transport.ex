defmodule Ethercat.Protocol.Transport do
  @moduledoc """
  Placeholder transport implementation.

  The final implementation will stream EtherCAT frames over an AF_PACKET socket.
  For now it behaves like a loopback device so the higher layers of the library
  can be exercised without physical hardware.
  """

  use GenServer

  alias Ethercat.Protocol.{Datagram, Frame}

  @type datagram :: Datagram.t()

  # -- Public API -----------------------------------------------------------

  @doc false
  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec transact([datagram], non_neg_integer()) :: {:ok, [datagram]} | {:error, term()}
  def transact(datagrams, _timeout_us) when is_list(datagrams) do
    GenServer.call(__MODULE__, {:transact, datagrams})
  end

  # -- GenServer -----------------------------------------------------------

  @impl true
  def init(state) do
    {:ok, Map.put(state, :last_index, 0)}
  end

  @impl true
  def handle_call({:transact, datagrams}, _from, %{last_index: idx} = state) do
    # For now we simply echo the datagrams back with a deterministic working
    # counter to keep the higher layers moving.
    {echoed, next_idx} =
      datagrams
      |> Enum.map_reduce(idx, fn dg, acc ->
        new_idx = rem(acc + 1, 256)
        echoed = %{dg | index: new_idx, working_counter: 1}
        {echoed, new_idx}
      end)

    # Build a frame just to exercise the encoder; the bytes themselves are not sent.
    _frame = Frame.build(echoed)

    {:reply, {:ok, echoed}, %{state | last_index: next_idx}}
  end
end
