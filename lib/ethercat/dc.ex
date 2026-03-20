defmodule EtherCAT.DC do
  @moduledoc """
  Distributed Clocks initialization and runtime maintenance.

  `EtherCAT.DC` is the specialist boundary for network-wide Distributed Clocks.
  One-time clock initialization and periodic FRMW/diagnostic maintenance are
  exposed here, while the internal runtime loop owns the active lock state.
  Normal application-facing runtime usage should stay on `EtherCAT` or
  `EtherCAT.Diagnostics`.

  ## Initialization

  `initialize_clocks/2` performs the one-time synchronization sequence used
  during startup:

  1. trigger receive-time latches on all slaves
  2. read one DC snapshot per slave
  3. pick the first DC-capable slave as the reference clock
  4. build the deterministic offset and propagation-delay plan
  5. write offsets and delays back to all DC-capable slaves
  6. reset PLL filters

  The current topology model is intentionally limited to a linear bus ordered
  by scan position.

  ## Runtime lock states

  The DC runtime reports lock state as ordinary runtime data:

  - `:disabled` - no DC config
  - `:inactive` - DC configured but runtime not started
  - `:unavailable` - runtime active with no monitorable stations
  - `:locking` - runtime active and converging
  - `:locked` - sync diffs are within threshold
  """

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

  @doc """
  Perform one-time DC clock initialization for the given scanned slave
  topology.
  """
  @spec initialize_clocks(Bus.server(), [{non_neg_integer(), binary()}]) ::
          {:ok, non_neg_integer(), [non_neg_integer()]} | {:error, term()}
  def initialize_clocks(bus, slave_topology), do: Init.initialize_clocks(bus, slave_topology)

  @doc """
  Return the current Distributed Clocks runtime status.

  Returns `{:error, :not_running}` when the DC runtime process is not active.
  """
  @spec status(server()) :: EtherCAT.DC.Status.t() | {:error, :not_running}
  def status(server \\ __MODULE__) do
    try do
      :gen_statem.call(server, :status)
    catch
      :exit, _reason -> {:error, :not_running}
    end
  end

  @doc """
  Wait until the DC runtime reports a locked status.
  """
  @spec await_locked(server(), pos_integer()) :: :ok | {:error, term()}
  def await_locked(server \\ __MODULE__, timeout_ms \\ 5_000)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    Runtime.await_locked(server, timeout_ms, &status/1)
  end
end
