defmodule EtherCAT.DC do
  @moduledoc File.read!(Path.join(__DIR__, "dc.md"))

  alias EtherCAT.Bus
  alias EtherCAT.DC.FSM
  alias EtherCAT.DC.Init
  alias EtherCAT.DC.Runtime

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
      start: {FSM, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5000
    }
  end

  @doc false
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts), do: FSM.start_link(opts)

  @spec initialize_clocks(Bus.server(), [{non_neg_integer(), binary()}]) ::
          {:ok, non_neg_integer(), [non_neg_integer()]} | {:error, term()}
  def initialize_clocks(bus, slave_topology), do: Init.initialize_clocks(bus, slave_topology)

  @spec status(server()) :: EtherCAT.DC.Status.t() | {:error, :not_running}
  def status(server \\ __MODULE__) do
    try do
      :gen_statem.call(server, :status)
    catch
      :exit, _reason -> {:error, :not_running}
    end
  end

  @spec await_locked(server(), pos_integer()) :: :ok | {:error, term()}
  def await_locked(server \\ __MODULE__, timeout_ms \\ 5_000)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    Runtime.await_locked(server, timeout_ms, &status/1)
  end
end
