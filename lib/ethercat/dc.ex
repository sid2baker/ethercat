defmodule EtherCAT.DC do
  @moduledoc File.read!(Path.join(__DIR__, "dc.md"))

  @behaviour :gen_statem

  alias EtherCAT.Bus
  alias EtherCAT.DC.Runtime
  alias EtherCAT.DC.State

  @type server :: :gen_statem.server_ref()

  @enforce_keys [
    :bus,
    :ref_station,
    :config,
    :monitored_stations,
    :tick_interval_ms,
    :diagnostic_interval_cycles,
    :lock_state
  ]
  defstruct [
    :bus,
    :ref_station,
    :config,
    :monitored_stations,
    :tick_interval_ms,
    :diagnostic_interval_cycles,
    :lock_state,
    :max_sync_diff_ns,
    :last_sync_check_at_ms,
    notify_recovered_on_success?: false,
    cycle_count: 0,
    fail_count: 0
  ]

  @type t :: %__MODULE__{
          bus: Bus.server(),
          ref_station: non_neg_integer(),
          config: EtherCAT.DC.Config.t(),
          monitored_stations: [non_neg_integer()],
          tick_interval_ms: pos_integer(),
          diagnostic_interval_cycles: pos_integer(),
          cycle_count: non_neg_integer(),
          fail_count: non_neg_integer(),
          lock_state: EtherCAT.DC.Status.lock_state(),
          max_sync_diff_ns: non_neg_integer() | nil,
          last_sync_check_at_ms: integer() | nil,
          notify_recovered_on_success?: boolean()
        }

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5000
    }
  end

  @doc """
  Start the DC runtime maintenance process.

  Options:
    - `:bus` (required)
    - `:ref_station` (required)
    - `:config` (required) — `%EtherCAT.DC.Config{}`
    - `:monitored_stations` — ordered DC-capable stations for `0x092C` diagnostics
    - `:tick_interval_ms` — optional runtime tick override for tests/debugging
    - `:diagnostic_interval_cycles` — optional diagnostic cadence override for tests/debugging
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    :gen_statem.start_link({:local, __MODULE__}, __MODULE__, opts, [])
  end

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts), do: {:ok, :running, State.new(opts)}

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
