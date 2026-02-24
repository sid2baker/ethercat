defmodule EtherCAT.Master do
  @moduledoc false

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.{Bus, Directory}

  defmodule State do
    @moduledoc false
    defstruct bus_ref: nil,
              config: nil,
              directory: nil,
              status: :idle,
              reason: nil
  end

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

  # -- Public API -----------------------------------------------------------

  @spec start(map()) :: {:ok, reference()} | {:error, term()}
  def start(config) do
    :gen_statem.call(__MODULE__, {:start, config})
  end

  @spec stop(reference()) :: :ok | {:error, term()}
  def stop(ref) do
    :gen_statem.call(__MODULE__, {:stop, ref})
  end

  def read(ref, device, signal) do
    :gen_statem.call(__MODULE__, {:read, ref, device, signal})
  end

  def write(ref, device, signal, value) do
    :gen_statem.call(__MODULE__, {:write, ref, device, signal, value})
  end

  def subscribe(ref, device, signal) do
    :gen_statem.call(__MODULE__, {:subscribe, ref, device, signal, self()})
  end

  def unsubscribe(_ref, device, signal) do
    Registry.unregister(EtherCAT.SignalRegistry, {device, signal})
    :ok
  end

  def status(ref) do
    :gen_statem.call(__MODULE__, {:status, ref})
  end

  # -- :gen_statem ---------------------------------------------------------

  def start_link(_arg) do
    :gen_statem.start_link({:local, __MODULE__}, __MODULE__, %State{}, [])
  end

  @impl true
  def callback_mode, do: [:handle_event_function]

  @impl true
  def init(state) do
    {:ok, :initializing, state}
  end

  # Initialising -----------------------------------------------------------

  @impl true
  def handle_event({:call, from}, {:start, config}, :initializing, state) do
    case do_start(config) do
      {:ok, new_state} ->
        {:next_state, :operational, new_state, [{:reply, from, {:ok, new_state.bus_ref}}]}

      {:error, reason} ->
        Logger.error("Failed to start EtherCAT bus: #{inspect(reason)}")
        faulted = %{state | status: :fault, reason: reason}
        {:next_state, :fault, faulted, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, _event, :initializing, _state) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_started}}]}
  end

  # Operational ------------------------------------------------------------

  def handle_event({:call, from}, {:stop, ref}, :operational, %{bus_ref: ref}) do
    {:next_state, :initializing, %State{}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:stop, _}, :operational, _state) do
    {:keep_state_and_data, [{:reply, from, {:error, :unknown_bus}}]}
  end

  def handle_event({:call, from}, {:status, ref}, :operational, %{bus_ref: ref}) do
    report = %{state: :operational, reason: nil}
    {:keep_state_and_data, [{:reply, from, {:ok, report}}]}
  end

  def handle_event(
        {:call, from},
        {:read, ref, device, signal},
        :operational,
        %{bus_ref: ref} = state
      ) do
    reply = Directory.fetch(state.directory, device, signal)
    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  def handle_event({:call, from}, {:write, ref, device, signal, value}, :operational, %{
        bus_ref: ref
      }) do
    reply = Bus.enqueue_write(device, signal, value)
    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  def handle_event({:call, from}, {:subscribe, ref, device, signal, pid}, :operational, %{
        bus_ref: ref
      }) do
    Registry.register(EtherCAT.SignalRegistry, {device, signal}, pid)
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:status, _ref}, :fault, state) do
    {:keep_state_and_data, [{:reply, from, {:error, state.reason}}]}
  end

  def handle_event({:call, from}, {:start, _config}, :operational, _state) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_started}}]}
  end

  def handle_event({:call, from}, _event, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_request}}]}
  end

  # -- Helpers --------------------------------------------------------------

  defp do_start(config) do
    with {:ok, devices} <- Bus.run_scanner(config),
         {:ok, directory} <- Directory.build(devices) do
      {:ok,
       %State{
         bus_ref: make_ref(),
         config: config,
         directory: directory,
         status: :operational,
         reason: nil
       }}
    end
  end
end
