defmodule EtherCAT.Master do
  @moduledoc false

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.{DC, Domain, Bus, Slave, Telemetry}
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.DC.Status, as: DCStatus
  alias EtherCAT.Master.Config
  alias EtherCAT.Master.InitReset
  alias EtherCAT.Master.InitRecovery
  alias EtherCAT.Master.InitVerification
  alias EtherCAT.Slave.Registers

  @base_station 0x1000

  # Scanning: poll every 100 ms, require 1 s of stable identical readings
  @scan_poll_ms 100
  @scan_stable_ms 1_000

  # Configuring: 30 s to receive :preop notifications from all slaves
  @configuring_timeout_ms 30_000

  # Bus frame timeout tuning:
  # base + per-slave budget keeps timeout proportional to bus size, then capped
  # to a fraction of cycle time so one stalled frame does not block multiple cycles.
  @frame_timeout_base_us 200
  @frame_timeout_per_slave_us 40
  @frame_timeout_cycle_margin_pct 90
  @frame_timeout_min_us 500
  @frame_timeout_max_ms 10
  @degraded_retry_ms 1_000
  @init_poll_limit 100
  @init_poll_interval_ms 10

  defstruct [
    :bus_ref,
    :dc_ref,
    # station address of the DC reference clock slave (nil if no DC)
    :dc_ref_station,
    :dc_stations,
    :domain_configs,
    :slave_configs,
    :dc_config,
    :frame_timeout_override_ms,
    activation_phase: :preop_ready,
    base_station: @base_station,
    activatable_slaves: [],
    slaves: [],
    # [{monotonic_ms, count}] — sliding window for scan stability
    scan_window: [],
    slave_count: nil,
    # MapSet of slave names still waiting to report :preop
    pending_preop: MapSet.new(),
    # %{slave_name => {target_state, reason}} for startup activation failures
    activation_failures: %{},
    # %{fault_key => reason} for runtime degradations that are not retried via Slave.request/2
    runtime_faults: %{},
    # last terminal session failure retained after returning to :idle
    last_failure: nil,
    # blocked await_running callers — replied when :running is entered
    await_callers: [],
    # blocked await_operational callers — replied when cyclic operation is live
    await_operational_callers: [],
    # %{monitor_ref => domain_id} — crash detection for running domains
    domain_refs: %{},
    # %{monitor_ref => slave_name} — crash detection for running slaves
    slave_refs: %{}
  ]

  # -- Public API ------------------------------------------------------------

  @doc """
  Start the master: open a bus and begin scanning for slaves.

  Options:
    - `:interface` (required) — e.g. `"eth0"`
    - `:slaves` — list of slave config entries, default `[]`. Each entry is a
      `%EtherCAT.Slave.Config{}` (or equivalent keyword list) with keys: `:name`, `:driver`,
      `:config`, `:process_data`, `:target_state`, and optional `:health_poll_ms`.
      `process_data` declares what the slave should register while in PREOP:
      - `:none`
      - `{:all, domain_id}`
      - `[{pdo_name, domain_id}]`
      `target_state` is `:op` or `:preop`. `nil` entries are rejected. If omitted,
      dynamic default slaves are started for all discovered stations and held in
      `:preop` for runtime configuration.
    - `:domains` — list of domain specs, default `[]`. Each entry is a keyword list with
      keys `:id` (atom, required), `:cycle_time_us` (required), and optional
      `:miss_threshold`. The master owns logical address allocation.
    - `:base_station` — starting station address, default `0x1000`
    - `:dc` — `%EtherCAT.DC.Config{}` for master-wide Distributed Clocks, or `nil` to disable DC
    - `:frame_timeout_ms` — optional fixed bus frame response timeout (ms); if omitted,
      master auto-tunes from slave count + cycle time
    - any other option is forwarded to `Bus.start_link/1` unchanged
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: safe_call({:start, opts})

  @doc "Stop the master: shut down all slaves, domains, and the bus. Returns `:already_stopped` if not running."
  @spec stop() :: :ok | :already_stopped
  def stop do
    try do
      :gen_statem.call(__MODULE__, :stop)
    catch
      :exit, {:noproc, _} -> :already_stopped
    end
  end

  @doc "Return `[%{name:, station:, server:, pid:}]` for all named slaves."
  @spec slaves() ::
          [
            %{
              name: atom(),
              station: non_neg_integer(),
              server: :gen_statem.server_ref(),
              pid: pid() | nil
            }
          ]
          | {:error, :not_started}
  def slaves, do: safe_call(:slaves)

  @doc "Return `[{id, cycle_time_us, pid}]` for all running domains."
  @spec domains() :: list() | {:error, :not_started}
  def domains, do: safe_call(:domains)

  @doc "Return the stable bus server reference."
  @spec bus() :: Bus.server() | nil | {:error, :not_started}
  def bus, do: safe_call(:bus)

  @doc "Return the current master state atom (`:idle | :scanning | :configuring | :running | :degraded | :recovering`)."
  @spec state() :: atom() | {:error, :not_started}
  def state, do: safe_call(:state)

  @doc """
  Return the last terminal startup/runtime failure retained after the master
  returned to `:idle`.
  """
  @spec last_failure() :: map() | nil | {:error, :not_started}
  def last_failure, do: safe_call(:last_failure)

  @doc """
  Return the current session phase.

  Unlike `state/0`, this is the public lifecycle view and distinguishes between
  PREOP-ready startup and fully operational cyclic runtime. Runtime recovery is
  reported through the public degraded phase.
  """
  @spec phase() ::
          :idle
          | :scanning
          | :configuring
          | :preop_ready
          | :operational
          | :degraded
          | {:error, :not_started}
  def phase, do: safe_call(:phase)

  @doc """
  Configure a discovered slave while the session is still in PREOP.

  Keyword-list updates merge into the current config. `%EtherCAT.Slave.Config{}`
  replaces the current declarative config for that slave.
  """
  @spec configure_slave(atom(), keyword() | EtherCAT.Slave.Config.t()) :: :ok | {:error, term()}
  def configure_slave(slave_name, spec) do
    safe_call({:configure_slave, slave_name, spec})
  end

  @doc """
  Start cyclic operation after dynamic PREOP configuration.

  This starts DC runtime, starts all domains cycling, and advances every slave
  whose `target_state` is `:op`.
  """
  @spec activate() :: :ok | {:error, term()}
  def activate do
    safe_call(:activate)
  end

  @doc """
  Update the live cycle period of a configured domain.

  This forwards the change to the running `Domain` process. The master keeps
  the initial domain plan; live period changes are owned by the `Domain`
  runtime and exposed through `domains/0` / `Domain.info/1`.
  """
  @spec update_domain_cycle_time(atom(), pos_integer()) :: :ok | {:error, term()}
  def update_domain_cycle_time(domain_id, cycle_time_us)
      when is_atom(domain_id) and is_integer(cycle_time_us) and cycle_time_us > 0 do
    safe_call({:update_domain_cycle_time, domain_id, cycle_time_us})
  end

  @doc """
  Block until the master reaches `:running`, then return `:ok`.

  Returns immediately if already `:running`. Returns `{:error, :timeout}` if
  the master does not reach `:running` within `timeout_ms` milliseconds.
  Returns `{:error, :not_started}` if the master process is not running.
  """
  @spec await_running(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_running(timeout_ms \\ 10_000) do
    safe_call(:await_running, timeout_ms)
  end

  @doc """
  Block until the master reaches operational cyclic runtime, then return `:ok`.

  This waits for DC/domain runtime to start and for `:op` promotion to complete.
  Returns `{:error, :not_started}` if the master is idle or not running.
  Returns `{:error, {:activation_failed, failures}}` for startup degradations and
  `{:error, {:runtime_degraded, faults}}` when runtime health has degraded.
  """
  @spec await_operational(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_operational(timeout_ms \\ 10_000) do
    safe_call(:await_operational, timeout_ms)
  end

  @doc "Return a Distributed Clocks status snapshot for the current session."
  @spec dc_status() :: DCStatus.t() | {:error, :not_started}
  def dc_status do
    safe_call(:dc_status)
  end

  @doc "Return the current DC reference clock as `%{name, station}`."
  @spec reference_clock() ::
          {:ok, %{name: atom() | nil, station: non_neg_integer()}} | {:error, term()}
  def reference_clock do
    safe_call(:reference_clock)
  end

  @doc """
  Wait for DC lock.

  Returns `:ok` once the active DC runtime reports `:locked`.
  """
  @spec await_dc_locked(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_dc_locked(timeout_ms \\ 5_000) do
    case safe_call(:dc_runtime) do
      {:ok, dc_server} -> DC.await_locked(dc_server, timeout_ms)
      {:error, _} = err -> err
    end
  end

  # -- child_spec / start_link -----------------------------------------------

  @doc false
  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]},
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc false
  def start_link(_arg) do
    :gen_statem.start_link({:local, __MODULE__}, __MODULE__, %__MODULE__{}, [])
  end

  # -- :gen_statem callbacks -------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(data), do: {:ok, :idle, data}

  # :idle --------------------------------------------------------------------

  @impl true
  def handle_event(:enter, _old, :idle, _data), do: :keep_state_and_data

  def handle_event({:call, from}, {:start, opts}, :idle, data) do
    with {:ok, start_config} <- normalize_start_options(opts),
         {:ok, bus_pid} <- start_session_bus(start_config.bus_opts) do
      bus_ref = Process.monitor(bus_pid)

      new_data = %{
        data
        | bus_ref: bus_ref,
          dc_ref: nil,
          base_station: start_config.base_station,
          dc_stations: [],
          slave_configs: start_config.slave_config,
          domain_configs: start_config.domain_config,
          dc_config: start_config.dc_config,
          frame_timeout_override_ms: start_config.frame_timeout_override_ms,
          activation_phase: :preop_ready,
          activatable_slaves: [],
          slaves: [],
          scan_window: [],
          pending_preop: MapSet.new(),
          activation_failures: %{},
          runtime_faults: %{},
          last_failure: nil,
          await_callers: [],
          await_operational_callers: []
      }

      {:next_state, :scanning, new_data, [{:reply, from, :ok}]}
    else
      {:error, _} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def handle_event({:call, from}, {:start, _}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_started}}]}
  end

  def handle_event({:call, from}, :state, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, :idle}]}
  end

  def handle_event({:call, from}, :last_failure, :idle, data) do
    {:keep_state_and_data, [{:reply, from, data.last_failure}]}
  end

  def handle_event({:call, from}, :phase, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, :idle}]}
  end

  def handle_event({:call, from}, :await_running, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_started}}]}
  end

  def handle_event({:call, from}, :await_operational, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_started}}]}
  end

  def handle_event({:call, from}, :dc_status, :idle, data) do
    {:keep_state_and_data, [{:reply, from, dc_status_for(data)}]}
  end

  def handle_event({:call, from}, :reference_clock, :idle, data) do
    {:keep_state_and_data, [{:reply, from, reference_clock_reply(dc_status_for(data))}]}
  end

  def handle_event({:call, from}, :dc_runtime, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_started}}]}
  end

  def handle_event({:call, from}, :stop, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, :already_stopped}]}
  end

  def handle_event({:call, from}, _event, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_started}}]}
  end

  # :scanning ----------------------------------------------------------------

  def handle_event(:enter, _old, :scanning, _data) do
    {:keep_state_and_data, [{{:timeout, :scan_poll}, 0, nil}]}
  end

  def handle_event({:timeout, :scan_poll}, nil, :scanning, data) do
    now_ms = System.monotonic_time(:millisecond)

    new_window =
      case Bus.transaction(bus_server(data), Transaction.brd(Registers.esc_type())) do
        {:ok, [%{wkc: n}]} ->
          # Prepend new reading; keep enough history to measure a full stable span
          window = [{now_ms, n} | data.scan_window]
          Enum.filter(window, fn {t, _} -> now_ms - t <= @scan_stable_ms + @scan_poll_ms end)

        _ ->
          # Failed transaction resets the window
          []
      end

    if stable?(new_window, now_ms) do
      [{_, slave_count} | _] = new_window
      tune_bus_frame_timeout(data, slave_count)
      Logger.info("[Master] bus stable — #{slave_count} slave(s)")
      config_data = %{data | scan_window: [], slave_count: slave_count}

      case configure_network(config_data) do
        {:ok, configured} ->
          if MapSet.size(configured.pending_preop) == 0 do
            Logger.info("[Master] all slaves in :preop — activating")

            case activate_network(configured) do
              {:ok, active_data} ->
                {:next_state, :running, active_data}

              {:degraded, degraded_data} ->
                {:next_state, :degraded, degraded_data}

              {:error, reason, failed_data} ->
                Logger.error("[Master] activation failed: #{inspect(reason)}")
                stop_session(failed_data)

                reply_await_callers(
                  failed_data.await_callers,
                  {:error, {:activation_failed, reason}}
                )

                reply_await_callers(
                  failed_data.await_operational_callers,
                  {:error, {:activation_failed, reason}}
                )

                {:next_state, :idle, reset_master(failure_snapshot(:activation_failed, reason))}
            end
          else
            {:next_state, :configuring, configured}
          end

        {:error, reason, failed_data} ->
          Logger.error("[Master] configuration failed: #{inspect(reason)}")
          stop_session(failed_data)

          reply_await_callers(
            failed_data.await_callers,
            {:error, {:configuration_failed, reason}}
          )

          reply_await_callers(
            failed_data.await_operational_callers,
            {:error, {:configuration_failed, reason}}
          )

          {:next_state, :idle, reset_master(failure_snapshot(:configuration_failed, reason))}
      end
    else
      {:keep_state, %{data | scan_window: new_window},
       [{{:timeout, :scan_poll}, @scan_poll_ms, nil}]}
    end
  end

  def handle_event({:call, from}, :stop, :scanning, data) do
    stop_session(data)
    reply_await_callers(data.await_operational_callers, {:error, :stopped})
    {:next_state, :idle, reset_master(data.last_failure), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, :scanning, data) do
    {:keep_state, %{data | await_callers: [from | data.await_callers]}}
  end

  def handle_event({:call, from}, :await_operational, :scanning, data) do
    {:keep_state, %{data | await_operational_callers: [from | data.await_operational_callers]}}
  end

  # :configuring -------------------------------------------------------------

  def handle_event(:enter, _old, :configuring, _data) do
    {:keep_state_and_data, [{{:timeout, :configuring}, @configuring_timeout_ms, nil}]}
  end

  def handle_event(:info, {:slave_ready, name, :preop}, :configuring, data) do
    new_pending = MapSet.delete(data.pending_preop, name)
    Logger.debug("[Master] slave #{inspect(name)} reached :preop")

    if MapSet.size(new_pending) == 0 do
      Logger.info("[Master] all slaves in :preop — activating")

      case activate_network(%{data | pending_preop: new_pending}) do
        {:ok, active_data} ->
          {:next_state, :running, active_data, [{{:timeout, :configuring}, :cancel}]}

        {:degraded, degraded_data} ->
          {:next_state, :degraded, degraded_data, [{{:timeout, :configuring}, :cancel}]}

        {:error, reason, failed_data} ->
          Logger.error("[Master] activation failed: #{inspect(reason)}")
          stop_session(failed_data)

          reply_await_callers(
            failed_data.await_callers,
            {:error, {:activation_failed, reason}}
          )

          reply_await_callers(
            failed_data.await_operational_callers,
            {:error, {:activation_failed, reason}}
          )

          {:next_state, :idle, reset_master(failure_snapshot(:activation_failed, reason)),
           [{{:timeout, :configuring}, :cancel}]}
      end
    else
      {:keep_state, %{data | pending_preop: new_pending}}
    end
  end

  def handle_event({:timeout, :configuring}, nil, :configuring, data) do
    remaining = MapSet.to_list(data.pending_preop)
    Logger.error("[Master] configuring timed out; slaves not in :preop: #{inspect(remaining)}")
    stop_session(data)
    reply_await_callers(data.await_callers, {:error, :configuring_timeout})
    reply_await_callers(data.await_operational_callers, {:error, :configuring_timeout})
    {:next_state, :idle, reset_master(failure_snapshot(:configuring_timeout, remaining))}
  end

  def handle_event({:call, from}, :stop, :configuring, data) do
    stop_session(data)
    reply_await_callers(data.await_callers, {:error, :stopped})
    reply_await_callers(data.await_operational_callers, {:error, :stopped})
    {:next_state, :idle, reset_master(data.last_failure), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, :configuring, data) do
    {:keep_state, %{data | await_callers: [from | data.await_callers]}}
  end

  def handle_event({:call, from}, :await_operational, :configuring, data) do
    {:keep_state, %{data | await_operational_callers: [from | data.await_operational_callers]}}
  end

  # :running -----------------------------------------------------------------

  def handle_event(:enter, _old, :running, %{activation_phase: :preop_ready} = data) do
    Logger.info("[Master] running — slaves ready in PREOP, waiting for explicit activate/0")
    reply_await_callers(data.await_callers, :ok)
    {:keep_state, %{data | await_callers: []}}
  end

  def handle_event(:enter, _old, :running, data) do
    Logger.info("[Master] running")
    reply_await_callers(data.await_callers, :ok)
    reply_await_callers(data.await_operational_callers, :ok)
    {:keep_state, %{data | await_callers: [], await_operational_callers: []}}
  end

  def handle_event({:call, from}, :stop, :running, data) do
    stop_session(data)
    reply_await_callers(data.await_operational_callers, {:error, :stopped})
    {:next_state, :idle, reset_master(data.last_failure), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, :running, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_operational, :running, %{activation_phase: :operational}) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_operational, :running, data) do
    {:keep_state, %{data | await_operational_callers: [from | data.await_operational_callers]}}
  end

  def handle_event({:call, from}, {:configure_slave, slave_name, spec}, :running, data) do
    case configure_discovered_slave(data, slave_name, spec) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, :activate, :running, %{activation_phase: :operational}) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_activated}}]}
  end

  def handle_event({:call, from}, :activate, :running, %{activation_phase: :preop_ready} = data) do
    case activate_network(data) do
      {:ok, active_data} ->
        reply_await_callers(active_data.await_operational_callers, :ok)

        {:keep_state, %{active_data | await_operational_callers: []}, [{:reply, from, :ok}]}

      {:degraded, degraded_data} ->
        {:next_state, :degraded, degraded_data, [{:reply, from, :ok}]}

      {:error, reason, _failed_data} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  # :degraded ----------------------------------------------------------------

  def handle_event(:enter, _old, :degraded, data) do
    Logger.warning("[Master] degraded — #{degraded_summary(data)}")

    reply_await_callers(data.await_callers, degraded_reply(data))
    reply_await_callers(data.await_operational_callers, degraded_reply(data))

    {:keep_state, %{data | await_callers: [], await_operational_callers: []},
     [{{:timeout, :degraded_retry}, @degraded_retry_ms, nil}]}
  end

  def handle_event({:timeout, :degraded_retry}, nil, :degraded, data) do
    case retry_degraded_state(data) do
      {:ok, healed_data} ->
        {:next_state, :running, healed_data}

      {:recovering, still_degraded} ->
        {:keep_state, still_degraded, [{{:timeout, :degraded_retry}, @degraded_retry_ms, nil}]}
    end
  end

  def handle_event({:call, from}, :stop, :degraded, data) do
    stop_session(data)
    reply_await_callers(data.await_operational_callers, {:error, :stopped})
    {:next_state, :idle, reset_master(data.last_failure), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, :degraded, data) do
    {:keep_state_and_data, [{:reply, from, degraded_reply(data)}]}
  end

  def handle_event({:call, from}, :await_operational, :degraded, data) do
    {:keep_state_and_data, [{:reply, from, degraded_reply(data)}]}
  end

  def handle_event({:call, from}, {:configure_slave, _slave_name, _spec}, :degraded, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :activation_in_progress}}]}
  end

  def handle_event({:call, from}, :activate, :degraded, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :activation_in_progress}}]}
  end

  # :recovering --------------------------------------------------------------

  def handle_event(:enter, _old, :recovering, data) do
    Logger.warning("[Master] recovering — #{recovering_summary(data)}")

    reply_await_callers(data.await_callers, recovering_reply(data))
    reply_await_callers(data.await_operational_callers, recovering_reply(data))

    {:keep_state, %{data | await_callers: [], await_operational_callers: []},
     [{{:timeout, :degraded_retry}, @degraded_retry_ms, nil}]}
  end

  def handle_event({:timeout, :degraded_retry}, nil, :recovering, data) do
    case retry_recovering_state(data) do
      {:ok, healed_data} ->
        {:next_state, :running, healed_data}

      {:recovering, still_recovering} ->
        {:keep_state, still_recovering, [{{:timeout, :degraded_retry}, @degraded_retry_ms, nil}]}
    end
  end

  def handle_event({:call, from}, :stop, :recovering, data) do
    stop_session(data)
    reply_await_callers(data.await_operational_callers, {:error, :stopped})
    {:next_state, :idle, reset_master(data.last_failure), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, :recovering, data) do
    {:keep_state_and_data, [{:reply, from, recovering_reply(data)}]}
  end

  def handle_event({:call, from}, :await_operational, :recovering, data) do
    {:keep_state_and_data, [{:reply, from, recovering_reply(data)}]}
  end

  def handle_event({:call, from}, {:configure_slave, _slave_name, _spec}, :recovering, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :recovery_in_progress}}]}
  end

  def handle_event({:call, from}, :activate, :recovering, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :recovery_in_progress}}]}
  end

  # -- Shared handlers (all non-idle states) ---------------------------------

  # Query handlers — work in all active states
  def handle_event({:call, from}, :state, state, _data) do
    {:keep_state_and_data, [{:reply, from, state}]}
  end

  def handle_event({:call, from}, :phase, state, data) do
    {:keep_state_and_data, [{:reply, from, phase_for(state, data)}]}
  end

  def handle_event({:call, from}, :last_failure, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.last_failure}]}
  end

  def handle_event({:call, from}, :dc_status, _state, data) do
    {:keep_state_and_data, [{:reply, from, dc_status_for(data)}]}
  end

  def handle_event({:call, from}, :reference_clock, _state, data) do
    {:keep_state_and_data, [{:reply, from, reference_clock_reply(dc_status_for(data))}]}
  end

  def handle_event({:call, from}, :dc_runtime, _state, %{dc_config: nil}) do
    {:keep_state_and_data, [{:reply, from, {:error, :dc_disabled}}]}
  end

  def handle_event({:call, from}, :dc_runtime, _state, _data) do
    if dc_running?() do
      {:keep_state_and_data, [{:reply, from, {:ok, dc_server()}}]}
    else
      {:keep_state_and_data, [{:reply, from, {:error, :dc_inactive}}]}
    end
  end

  def handle_event({:call, from}, :slaves, _state, data) do
    result =
      Enum.map(data.slaves, fn {name, station} ->
        %{name: name, station: station, server: slave_server(name), pid: lookup_slave_pid(name)}
      end)

    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def handle_event({:call, from}, :domains, _state, data) do
    result =
      (data.domain_configs || [])
      |> Enum.flat_map(fn config ->
        case Registry.lookup(EtherCAT.Registry, {:domain, config.id}) do
          [{pid, _}] ->
            case Domain.info(config.id) do
              {:ok, %{cycle_time_us: cycle_time_us}} -> [{config.id, cycle_time_us, pid}]
              _ -> []
            end

          [] ->
            []
        end
      end)

    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def handle_event({:call, from}, :bus, _state, data) do
    {:keep_state_and_data, [{:reply, from, bus_public_ref(data)}]}
  end

  def handle_event(
        {:call, from},
        {:update_domain_cycle_time, domain_id, cycle_time_us},
        _state,
        data
      )
      when is_atom(domain_id) and is_integer(cycle_time_us) and cycle_time_us > 0 do
    case update_domain_cycle_time(data, domain_id, cycle_time_us) do
      :ok ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  # Catch-all for unrecognized calls in any active state
  def handle_event({:call, from}, _event, state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, state}}]}
  end

  # Bus crashed — clean up and return to idle
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, _state, data)
      when ref == data.bus_ref and not is_nil(ref) do
    Logger.error("[Master] bus crashed (#{inspect(reason)}) — returning to idle")
    reply_await_callers(data.await_callers, {:error, {:bus_down, reason}})
    reply_await_callers(data.await_operational_callers, {:error, {:bus_down, reason}})
    stop_session(data)
    {:next_state, :idle, reset_master(failure_snapshot(:bus_down, reason))}
  end

  # Domain process crashed unexpectedly
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, state, data)
      when is_map_key(data.domain_refs, ref) do
    {id, refs} = Map.pop(data.domain_refs, ref)
    Logger.error("[Master] domain #{id} crashed: #{inspect(reason)}")
    Telemetry.domain_crashed(id, reason)

    data_with_refs = %{data | domain_refs: refs}
    recovering_data = put_runtime_fault(data_with_refs, {:domain, id}, {:crashed, reason})
    transition_runtime_fault(state, recovering_data)
  end

  # Slave process crashed unexpectedly
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, state, data)
      when is_map_key(data.slave_refs, ref) do
    {name, refs} = Map.pop(data.slave_refs, ref)
    Logger.error("[Master] slave #{name} crashed: #{inspect(reason)}")
    Telemetry.slave_crashed(name, reason)

    recovering_data =
      data
      |> Map.put(:slave_refs, refs)
      |> put_runtime_fault({:slave, name}, {:crashed, reason})

    transition_runtime_fault(state, recovering_data)
  end

  # DC runtime crashed unexpectedly
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, state, data)
      when ref == data.dc_ref and not is_nil(ref) do
    Logger.error("[Master] DC runtime crashed: #{inspect(reason)}")

    recovering_data =
      data
      |> Map.put(:dc_ref, nil)
      |> put_runtime_fault({:dc, :runtime}, {:crashed, reason})

    transition_runtime_fault(state, recovering_data)
  end

  # Stale :DOWN from a previous session — ignore
  def handle_event(:info, {:DOWN, _ref, :process, _pid, _reason}, _state, _data) do
    :keep_state_and_data
  end

  # Domain stopped cycling due to consecutive misses
  def handle_event(:info, {:domain_stopped, id, reason}, state, data) do
    Logger.error("[Master] domain #{id} stopped cycling: #{inspect(reason)}")
    recovering_data = put_runtime_fault(data, {:domain, id}, {:stopped, reason})
    transition_runtime_fault(state, recovering_data)
  end

  def handle_event(:info, {:domain_cycle_invalid, id, reason}, :running, data) do
    Logger.warning("[Master] domain #{id} cycle invalid: #{inspect(reason)} — entering recovery")
    {:next_state, :recovering, put_runtime_fault(data, {:domain, id}, {:cycle_invalid, reason})}
  end

  def handle_event(:info, {:domain_cycle_invalid, id, reason}, :recovering, data) do
    Logger.warning("[Master] domain #{id} cycle still invalid: #{inspect(reason)}")
    {:keep_state, put_runtime_fault(data, {:domain, id}, {:cycle_invalid, reason})}
  end

  def handle_event(:info, {:domain_cycle_invalid, _id, _reason}, _state, _data) do
    :keep_state_and_data
  end

  def handle_event(:info, {:domain_cycle_recovered, id}, :recovering, data) do
    Logger.info("[Master] domain #{id} cycle recovered")

    case maybe_resume_running(clear_runtime_fault(data, {:domain, id})) do
      {:ok, healed_data} ->
        {:next_state, :running, healed_data}

      {:recovering, still_recovering} ->
        {:keep_state, still_recovering}
    end
  end

  def handle_event(:info, {:domain_cycle_recovered, _id}, _state, _data) do
    :keep_state_and_data
  end

  # Slave retreated to a lower ESM state (AL fault detected by health poll)
  def handle_event(:info, {:slave_retreated, name, target_state}, :running, data) do
    Logger.warning("[Master] slave #{name} retreated to #{target_state} — entering recovery")

    {:next_state, :recovering,
     put_runtime_fault(data, {:slave, name}, {:retreated, target_state})}
  end

  def handle_event(:info, {:slave_retreated, name, target_state}, :recovering, data) do
    Logger.warning("[Master] slave #{name} retreated to #{target_state} (already recovering)")
    {:keep_state, put_runtime_fault(data, {:slave, name}, {:retreated, target_state})}
  end

  def handle_event(:info, {:slave_retreated, name, target_state}, _state, _data) do
    Logger.warning("[Master] slave #{name} retreated to #{target_state} (already not running)")
    :keep_state_and_data
  end

  # Slave physically disconnected (health poll wkc=0 or bus error)
  def handle_event(:info, {:slave_down, name}, :running, data) do
    Logger.warning("[Master] slave #{name} disconnected — entering recovery")
    {:next_state, :recovering, put_runtime_fault(data, {:slave, name}, {:down, :disconnected})}
  end

  def handle_event(:info, {:slave_down, name}, :recovering, data) do
    Logger.warning("[Master] slave #{name} disconnected (already recovering)")
    {:keep_state, put_runtime_fault(data, {:slave, name}, {:down, :disconnected})}
  end

  def handle_event(:info, {:slave_reconnected, name}, :recovering, data) do
    Logger.info("[Master] slave #{name} link restored — authorizing reconnect")

    case Slave.authorize_reconnect(name) do
      :ok ->
        {:keep_state, put_runtime_fault(data, {:slave, name}, {:reconnecting, :authorized})}

      {:error, reason} ->
        Logger.warning(
          "[Master] slave #{name} reconnect authorization failed: #{inspect(reason)}"
        )

        {:keep_state, put_runtime_fault(data, {:slave, name}, {:reconnect_failed, reason})}
    end
  end

  # Slave reconnected and reached :preop — attempt to bring it back to :op
  def handle_event(:info, {:slave_ready, name, :preop}, :recovering, data) do
    Logger.info("[Master] slave #{name} reconnected and in :preop — requesting :op")

    case Slave.request(name, :op) do
      :ok ->
        recovered_data =
          data
          |> clear_runtime_fault({:slave, name})
          |> maybe_restart_stopped_domains()
          |> maybe_restart_dc_runtime()

        case maybe_resume_running(recovered_data) do
          {:ok, healed_data} ->
            {:next_state, :running, healed_data}

          {:recovering, still_recovering} ->
            {:keep_state, still_recovering}
        end

      {:error, reason} ->
        Logger.warning(
          "[Master] slave #{name} :op request failed after reconnect: #{inspect(reason)}"
        )

        {:keep_state, put_runtime_fault(data, {:slave, name}, {:preop, reason})}
    end
  end

  def handle_event(:info, {:dc_runtime_failed, reason}, :running, data) do
    Logger.warning("[Master] DC runtime failed: #{inspect(reason)} — entering recovery")
    {:next_state, :recovering, put_runtime_fault(data, {:dc, :runtime}, {:failed, reason})}
  end

  def handle_event(:info, {:dc_runtime_failed, reason}, :recovering, data) do
    Logger.warning("[Master] DC runtime still failing: #{inspect(reason)}")
    {:keep_state, put_runtime_fault(data, {:dc, :runtime}, {:failed, reason})}
  end

  def handle_event(:info, {:dc_runtime_recovered}, :recovering, data) do
    Logger.info("[Master] DC runtime recovered")

    case maybe_resume_running(clear_runtime_fault(data, {:dc, :runtime})) do
      {:ok, healed_data} ->
        {:next_state, :running, healed_data}

      {:recovering, still_recovering} ->
        {:keep_state, still_recovering}
    end
  end

  def handle_event(:info, {:dc_lock_lost, lock_state, max_sync_diff_ns}, :running, data)
      when not is_nil(data.dc_config) and data.dc_config.await_lock? do
    Logger.warning(
      "[Master] DC lock lost: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — entering recovery"
    )

    {:next_state, :recovering,
     put_runtime_fault(data, {:dc, :lock}, {lock_state, max_sync_diff_ns})}
  end

  def handle_event(:info, {:dc_lock_lost, lock_state, max_sync_diff_ns}, :recovering, data)
      when not is_nil(data.dc_config) and data.dc_config.await_lock? do
    Logger.warning(
      "[Master] DC lock still lost: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)}"
    )

    {:keep_state, put_runtime_fault(data, {:dc, :lock}, {lock_state, max_sync_diff_ns})}
  end

  def handle_event(:info, {:dc_lock_regained, max_sync_diff_ns}, :recovering, data)
      when not is_nil(data.dc_config) and data.dc_config.await_lock? do
    Logger.info("[Master] DC lock regained (max_sync_diff_ns=#{inspect(max_sync_diff_ns)})")

    case maybe_resume_running(clear_runtime_fault(data, {:dc, :lock})) do
      {:ok, healed_data} ->
        {:next_state, :running, healed_data}

      {:recovering, still_recovering} ->
        {:keep_state, still_recovering}
    end
  end

  # :slave_ready arriving while not configuring (e.g. restart race) — ignore
  def handle_event(:info, {:slave_ready, _name, _ready_state}, _state, _data) do
    :keep_state_and_data
  end

  # Catch-all — discard stale timeouts and unexpected messages
  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # -- Scan stability --------------------------------------------------------

  defp stable?([], _now_ms), do: false

  defp stable?(window, now_ms) do
    counts = Enum.map(window, fn {_, c} -> c end)
    oldest_t = elem(List.last(window), 0)
    span = now_ms - oldest_t

    span >= @scan_stable_ms and
      length(counts) >= 2 and
      length(Enum.uniq(counts)) == 1 and
      hd(counts) > 0
  end

  # -- Startup normalization -------------------------------------------------

  defp normalize_start_options(opts), do: Config.normalize_start_options(opts)

  defp start_session_bus(bus_opts) do
    DynamicSupervisor.start_child(
      EtherCAT.SessionSupervisor,
      {Bus, Keyword.put(bus_opts, :name, Bus)}
    )
  end

  defp configure_discovered_slave(%{activation_phase: :operational}, _slave_name, _spec) do
    {:error, :activation_already_started}
  end

  defp configure_discovered_slave(data, slave_name, spec) do
    with {:ok, current_config, config_idx} <-
           Config.fetch_slave_config(data.slave_configs || [], slave_name),
         {:ok, normalized_config} <-
           Config.normalize_runtime_slave_config(slave_name, spec, current_config),
         :ok <- ensure_known_domains(data, normalized_config),
         :ok <- ensure_slave_in_preop(slave_name),
         :ok <- maybe_apply_slave_configuration(slave_name, current_config, normalized_config) do
      updated_slave_configs = List.replace_at(data.slave_configs, config_idx, normalized_config)

      {:ok,
       %{
         data
         | slave_configs: updated_slave_configs,
           activatable_slaves: Config.activatable_slave_names(updated_slave_configs)
       }}
    end
  end

  defp ensure_known_domains(data, slave_config) do
    unknown_domains = Config.unknown_domain_ids(data.domain_configs || [], slave_config)

    case unknown_domains do
      [] -> :ok
      domains -> {:error, {:unknown_domains, domains}}
    end
  end

  defp ensure_slave_in_preop(slave_name) do
    case Slave.state(slave_name) do
      :preop -> :ok
      state -> {:error, {:not_preop, state}}
    end
  end

  defp maybe_apply_slave_configuration(slave_name, current_config, updated_config) do
    if Config.local_config_changed?(current_config, updated_config) do
      Slave.configure(
        slave_name,
        driver: updated_config.driver,
        config: updated_config.config,
        process_data: updated_config.process_data,
        sync: updated_config.sync,
        health_poll_ms: updated_config.health_poll_ms
      )
    else
      :ok
    end
  end

  defp update_domain_cycle_time(%{domain_configs: domain_configs}, domain_id, cycle_time_us) do
    if Enum.any?(domain_configs || [], &(&1.id == domain_id)) do
      Domain.update_cycle_time(domain_id, cycle_time_us)
    else
      {:error, {:unknown_domain, domain_id}}
    end
  end

  defp reset_master(last_failure), do: %__MODULE__{last_failure: last_failure}

  defp failure_snapshot(kind, reason) do
    %{
      kind: kind,
      reason: reason,
      at_ms: System.system_time(:millisecond)
    }
  end

  defp tune_bus_frame_timeout(data, slave_count) do
    if bus_running?() do
      target_ms = recommended_frame_timeout_ms(data, slave_count)

      case Bus.set_frame_timeout(bus_server(data), target_ms) do
        :ok ->
          Logger.info(
            "[Master] bus frame timeout set to #{target_ms}ms (slaves=#{slave_count}, dc_cycle_ns=#{inspect(dc_cycle_ns(data))})"
          )

          :ok

        {:error, reason} ->
          Logger.warning(
            "[Master] failed to tune bus frame timeout to #{target_ms}ms: #{inspect(reason)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  defp recommended_frame_timeout_ms(%{frame_timeout_override_ms: timeout_ms}, _slave_count)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    timeout_ms
  end

  defp recommended_frame_timeout_ms(data, slave_count)
       when is_integer(slave_count) and slave_count > 0 do
    by_topology_us = @frame_timeout_base_us + slave_count * @frame_timeout_per_slave_us

    by_cycle_us =
      case dc_cycle_ns(data) do
        cycle_ns when is_integer(cycle_ns) and cycle_ns > 0 ->
          div(cycle_ns * @frame_timeout_cycle_margin_pct, 100)

        _ ->
          @frame_timeout_max_ms * 1_000
      end

    budget_us = min(by_topology_us, by_cycle_us)
    timeout_us = max(budget_us, @frame_timeout_min_us)
    timeout_ms = ceil_div(timeout_us, 1_000)
    min(timeout_ms, @frame_timeout_max_ms)
  end

  defp recommended_frame_timeout_ms(_data, _slave_count), do: 1

  defp ceil_div(value, divisor) when is_integer(value) and is_integer(divisor) and divisor > 0 do
    div(value + divisor - 1, divisor)
  end

  defp station_for_position(data, pos), do: data.base_station + pos

  # -- Spec-aligned startup phases ------------------------------------------

  defp configure_network(data) do
    count = data.slave_count
    Logger.info("[Master] configuring #{count} slave(s)")

    with {:ok, stations} <- assign_station_addresses(data, count),
         {:ok, slave_topology} <- read_topology_statuses(data, stations),
         :ok <- reset_slaves_to_init(data, stations),
         {:ok, dc_ref_station, dc_stations} <- initialize_distributed_clocks(data, slave_topology),
         {:ok, domain_refs} <- start_domains(data, dc_ref_station),
         {:ok, effective_slave_configs, slaves, pending_preop, activatable_slaves, slave_refs} <-
           start_slaves(data, count, if(dc_ref_station, do: dc_cycle_ns(data), else: nil)) do
      {:ok,
       %{
         data
         | dc_ref_station: dc_ref_station,
           dc_stations: dc_stations,
           slave_configs: effective_slave_configs,
           slaves: slaves,
           pending_preop: MapSet.new(pending_preop),
           activatable_slaves: activatable_slaves,
           activation_failures: %{},
           activation_phase: :preop_ready,
           domain_refs: domain_refs,
           slave_refs: slave_refs
       }}
    else
      {:error, reason} ->
        {:error, reason, data}

      {:error, reason, started_slaves} ->
        {:error, reason, %{data | slaves: started_slaves}}
    end
  end

  defp assign_station_addresses(data, count) do
    stations = Enum.map(0..(count - 1), &station_for_position(data, &1))

    result =
      Enum.reduce_while(0..(count - 1), :ok, fn pos, :ok ->
        station = station_for_position(data, pos)

        case Bus.transaction(
               bus_server(data),
               Transaction.apwr(pos, Registers.station_address(station))
             ) do
          {:ok, [%{wkc: 1}]} ->
            {:cont, :ok}

          {:ok, [%{wkc: wkc}]} ->
            {:halt, {:error, {:station_assign_failed, pos, station, {:unexpected_wkc, wkc}}}}

          {:error, reason} ->
            {:halt, {:error, {:station_assign_failed, pos, station, reason}}}
        end
      end)

    case result do
      :ok -> {:ok, stations}
      {:error, _} = err -> err
    end
  end

  defp read_topology_statuses(data, stations) do
    Enum.reduce_while(stations, {:ok, []}, fn station, {:ok, acc} ->
      case Bus.transaction(bus_server(data), Transaction.fprd(station, Registers.dl_status())) do
        {:ok, [%{data: status, wkc: 1}]} ->
          {:cont, {:ok, [{station, status} | acc]}}

        {:ok, [%{wkc: wkc}]} ->
          {:halt, {:error, {:topology_read_failed, station, {:unexpected_wkc, wkc}}}}

        {:error, reason} ->
          {:halt, {:error, {:topology_read_failed, station, reason}}}
      end
    end)
    |> case do
      {:ok, topology_rev} -> {:ok, Enum.reverse(topology_rev)}
      {:error, _} = err -> err
    end
  end

  defp reset_slaves_to_init(data, stations) do
    count = length(stations)

    with :ok <- reset_slaves_to_default(data, count),
         :ok <- broadcast_init_ack(data, count),
         :ok <- verify_init_states(data, stations, @init_poll_limit) do
      :ok
    else
      {:error, _} = err ->
        err
    end
  end

  defp reset_slaves_to_default(data, count) do
    case Bus.transaction(bus_server(data), InitReset.transaction()) do
      {:ok, replies} ->
        case InitReset.validate_results(replies, count) do
          :ok ->
            :ok

          {:error, wkcs, ^count} ->
            {:error, {:init_default_reset_failed, wkcs, count}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp broadcast_init_ack(data, count) do
    case Bus.transaction(bus_server(data), Transaction.bwr(Registers.al_control(0x11))) do
      {:ok, replies} ->
        case InitReset.validate_init_ack_reply(replies, count) do
          :ok ->
            :ok

          {:partial, wkc, ^count} ->
            Logger.warning(
              "[Master] partial broadcast init-ack response during reset: wkc=#{wkc} expected<=#{count}; continuing with per-station init verification"
            )

            :ok

          {:error, {:unexpected_wkc, _, _} = reason} ->
            {:error, {:init_reset_failed, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp verify_init_states(_data, _stations, 0), do: {:error, :init_verification_exhausted}

  defp verify_init_states(data, stations, attempts_left) do
    statuses = Enum.map(stations, &read_init_status(data, &1))
    blocking = InitVerification.blocking_statuses(statuses)

    if blocking == [] do
      log_lingering_init_errors(InitVerification.lingering_error_statuses(statuses))
      :ok
    else
      if attempts_left == 1 do
        {:error, {:init_verification_failed, blocking}}
      else
        with :ok <- recover_init_states(data, blocking) do
          Process.sleep(@init_poll_interval_ms)
          verify_init_states(data, stations, attempts_left - 1)
        end
      end
    end
  end

  defp recover_init_states(data, statuses) do
    statuses
    |> InitRecovery.actions()
    |> Enum.reduce_while(:ok, fn
      {:ack_error, station, control}, :ok ->
        case write_al_control(data, station, control) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:init_recovery_failed, station, reason}}}
        end

      {:request_init, station, control}, :ok ->
        case write_al_control(data, station, control) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:init_recovery_failed, station, reason}}}
        end
    end)
  end

  defp write_al_control(data, station, control) do
    case Bus.transaction(
           bus_server(data),
           Transaction.fpwr(station, Registers.al_control(control))
         ) do
      {:ok, [%{wkc: 1}]} -> :ok
      {:ok, [%{wkc: wkc}]} -> {:error, {:unexpected_wkc, wkc}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_init_status(data, station) do
    case Bus.transaction(bus_server(data), Transaction.fprd(station, Registers.al_status())) do
      {:ok, [%{data: <<_::3, error::1, state::4, _::8>>, wkc: 1}]} ->
        %{
          station: station,
          state: state,
          error: error,
          error_code: if(error == 1, do: read_al_status_code(data, station), else: nil)
        }

      {:ok, [%{wkc: wkc}]} ->
        %{station: station, state: nil, error: nil, error_code: nil, wkc: wkc}

      {:error, reason} ->
        %{station: station, state: nil, error: nil, error_code: nil, error_reason: reason}
    end
  end

  defp read_al_status_code(data, station) do
    case Bus.transaction(bus_server(data), Transaction.fprd(station, Registers.al_status_code())) do
      {:ok, [%{data: <<code::16-little>>, wkc: 1}]} -> code
      _ -> nil
    end
  end

  defp log_lingering_init_errors([]), do: :ok

  defp log_lingering_init_errors(statuses) do
    Logger.debug(
      "[Master] continuing with slaves in INIT but with AL error latched: #{inspect(statuses)}"
    )
  end

  defp initialize_distributed_clocks(data, slave_topology) do
    if is_nil(data.dc_config) do
      {:ok, nil, []}
    else
      case DC.initialize_clocks(bus_server(data), slave_topology) do
        {:ok, ref_station, dc_stations} ->
          Logger.info("[Master] DC initialized, ref=0x#{Integer.to_string(ref_station, 16)}")
          {:ok, ref_station, dc_stations}

        {:error, :no_dc_capable_slave} ->
          Logger.debug("[Master] no DC-capable slaves found — running without DC")
          {:ok, nil, []}

        {:error, reason} ->
          Logger.warning("[Master] DC init failed (#{inspect(reason)}) — running without DC")
          {:ok, nil, []}
      end
    end
  end

  # Returns {:ok, domain_refs} where domain_refs is %{monitor_ref => domain_id}
  defp start_domains(data, _dc_ref_station) do
    Enum.reduce_while(data.domain_configs || [], {:ok, %{}}, fn entry, {:ok, refs} ->
      domain_opts = Config.domain_start_opts(entry)

      id = entry.id

      case DynamicSupervisor.start_child(
             EtherCAT.SessionSupervisor,
             {Domain, [{:bus, bus_server(data)} | domain_opts]}
           ) do
        {:ok, pid} ->
          {:cont, {:ok, Map.put(refs, Process.monitor(pid), id)}}

        {:error, {:already_started, pid}} ->
          {:cont, {:ok, Map.put(refs, Process.monitor(pid), id)}}

        {:error, reason} ->
          {:halt, {:error, {:domain_start_failed, id, reason}}}
      end
    end)
  end

  # Returns {:ok, effective_config, slaves_list, pending_preop_names, activatable_names, slave_refs}
  defp start_slaves(data, bus_count, dc_cycle_ns) do
    with {:ok, effective_config} <-
           Config.effective_slave_config(data.slave_configs || [], bus_count) do
      Enum.with_index(effective_config)
      |> Enum.reduce_while(
        {:ok, [], [], [], %{}},
        fn {entry, pos}, {:ok, slave_acc, pending_acc, activatable_acc, slave_refs} ->
          station = station_for_position(data, pos)
          name = entry.name

          opts = [
            bus: bus_server(data),
            station: station,
            name: name,
            driver: entry.driver,
            config: entry.config,
            process_data: entry.process_data,
            dc_cycle_ns: dc_cycle_ns,
            sync: entry.sync,
            health_poll_ms: entry.health_poll_ms
          ]

          case DynamicSupervisor.start_child(EtherCAT.SlaveSupervisor, {Slave, opts}) do
            {:ok, pid} ->
              next_activatable =
                if entry.target_state == :op do
                  [name | activatable_acc]
                else
                  activatable_acc
                end

              {:cont,
               {:ok, [{name, station} | slave_acc], [name | pending_acc], next_activatable,
                Map.put(slave_refs, Process.monitor(pid), name)}}

            {:error, reason} ->
              {:halt,
               {:error, {:slave_start_failed, name, station, reason}, Enum.reverse(slave_acc)}}
          end
        end
      )
      |> case do
        {:ok, slaves, pending, activatable, slave_refs} ->
          {:ok, effective_config, Enum.reverse(slaves), Enum.reverse(pending),
           Enum.reverse(activatable), slave_refs}

        {:error, reason, started_slaves} ->
          {:error, reason, started_slaves}

        {:error, _} = err ->
          err
      end
    end
  end

  # Runs synchronously in the scan/configuring handler before transitioning to :running.
  defp activate_network(%{activatable_slaves: []} = data) do
    Logger.info("[Master] dynamic startup: slaves held in :preop for runtime configuration")
    {:ok, %{data | activation_failures: %{}, activation_phase: :preop_ready}}
  end

  defp activate_network(data) do
    Logger.info("[Master] activating — starting DC, cyclic domains, and advancing slaves to :op")

    case start_dc_runtime(data) do
      {:ok, dc_data} ->
        with :ok <- start_domain_cycles(dc_data),
             :ok <- await_dc_lock_if_requested(dc_data) do
          activation_failures = activate_required_slaves(dc_data.activatable_slaves)

          activated_data = %{dc_data | activation_failures: activation_failures}

          if map_size(activation_failures) == 0 do
            {:ok, %{activated_data | activation_phase: :operational}}
          else
            Logger.warning(
              "[Master] activation incomplete; degraded mode for #{inspect(Map.keys(activation_failures))}"
            )

            {:degraded, %{activated_data | activation_phase: :operational}}
          end
        else
          {:error, reason} ->
            {:error, reason, data}
        end

      {:error, reason} ->
        {:error, reason, data}
    end
  end

  # -- Session teardown ------------------------------------------------------

  defp stop_session(data) do
    Enum.each(data.domain_refs, fn {ref, _id} -> Process.demonitor(ref, [:flush]) end)
    Enum.each(data.slave_refs, fn {ref, _name} -> Process.demonitor(ref, [:flush]) end)
    maybe_demonitor_dc(data.dc_ref)

    stop_dc_runtime()

    Enum.each(data.slaves || [], fn {name, _station} ->
      terminate_slave(name)
    end)

    Enum.each(Config.domain_ids(data.domain_configs || []), fn domain_id ->
      terminate_domain(domain_id)
    end)

    stop_bus()
  end

  defp start_dc_runtime(%{dc_ref_station: nil} = data), do: {:ok, %{data | dc_ref: nil}}

  defp start_dc_runtime(data) do
    case DynamicSupervisor.start_child(
           EtherCAT.SessionSupervisor,
           {DC,
            bus: bus_server(data),
            ref_station: data.dc_ref_station,
            monitored_stations: data.dc_stations,
            config: data.dc_config}
         ) do
      {:ok, pid} ->
        {:ok, %{data | dc_ref: Process.monitor(pid)}}

      {:error, {:already_started, pid}} ->
        {:ok, %{data | dc_ref: Process.monitor(pid)}}

      {:error, reason} ->
        {:error, {:dc_start_failed, reason}}
    end
  end

  defp start_domain_cycles(data) do
    Enum.reduce_while(Config.domain_ids(data.domain_configs || []), :ok, fn id, :ok ->
      case Domain.start_cycling(id) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:domain_cycle_start_failed, id, reason}}}
      end
    end)
  end

  defp await_dc_lock_if_requested(%{dc_config: nil}), do: :ok

  defp await_dc_lock_if_requested(%{dc_config: %{await_lock?: false}}), do: :ok

  defp await_dc_lock_if_requested(data) do
    timeout_ms = data.dc_config.lock_timeout_ms

    if dc_running?() do
      case DC.await_locked(dc_server(), timeout_ms) do
        :ok ->
          :ok

        {:error, :timeout} ->
          {:error, {:dc_lock_timeout, dc_status_for(data)}}

        {:error, reason} ->
          {:error, {:dc_lock_failed, reason}}
      end
    else
      {:error, {:dc_lock_unavailable, :no_active_dc_runtime}}
    end
  end

  defp activate_required_slaves(slave_names) do
    {safeop_ready, safeop_failures} =
      Enum.reduce(slave_names, {[], %{}}, fn name, {ready, failures} ->
        case Slave.request(name, :safeop) do
          :ok ->
            {[name | ready], failures}

          {:error, reason} ->
            Logger.warning("[Master] slave #{inspect(name)} → safeop failed: #{inspect(reason)}")
            {ready, Map.put(failures, name, {:safeop, reason})}
        end
      end)

    Enum.reduce(safeop_ready, safeop_failures, fn name, failures ->
      case Slave.request(name, :op) do
        :ok ->
          failures

        {:error, reason} ->
          Logger.warning("[Master] slave #{inspect(name)} → op failed: #{inspect(reason)}")
          Map.put(failures, name, {:op, reason})
      end
    end)
  end

  defp retry_degraded_state(%{activation_failures: failures} = data)
       when map_size(failures) == 0 do
    maybe_resume_running(data)
  end

  defp retry_degraded_state(%{activation_failures: failures} = data) do
    retried_failures =
      Enum.reduce(failures, %{}, fn
        {name, {:down, _}}, acc ->
          # Slave is physically disconnected; waiting for {:slave_ready} notification from slave
          Map.put(acc, name, {:down, :disconnected})

        {name, _last_failure}, acc ->
          case Slave.request(name, :op) do
            :ok ->
              acc

            {:error, reason} ->
              Logger.warning(
                "[Master] degraded retry: #{inspect(name)} still not in :op: #{inspect(reason)}"
              )

              Map.put(acc, name, {:op, reason})
          end
      end)

    maybe_resume_running(%{data | activation_failures: retried_failures})
  end

  defp retry_recovering_state(data) do
    data
    |> retry_recovering_slaves()
    |> maybe_restart_stopped_domains()
    |> maybe_restart_dc_runtime()
    |> maybe_resume_running()
  end

  defp phase_for(:idle, _data), do: :idle
  defp phase_for(:scanning, _data), do: :scanning
  defp phase_for(:configuring, _data), do: :configuring
  defp phase_for(:degraded, _data), do: :degraded
  defp phase_for(:recovering, _data), do: :degraded
  defp phase_for(:running, %{activation_phase: :operational}), do: :operational
  defp phase_for(:running, _data), do: :preop_ready

  defp dc_cycle_ns(%{dc_config: %{cycle_ns: cycle_ns}})
       when is_integer(cycle_ns) and cycle_ns > 0,
       do: cycle_ns

  defp dc_cycle_ns(_data), do: nil

  defp put_runtime_fault(data, key, reason) do
    %{data | runtime_faults: Map.put(data.runtime_faults, key, reason)}
  end

  defp clear_runtime_fault(data, key) do
    %{data | runtime_faults: Map.delete(data.runtime_faults, key)}
  end

  defp transition_runtime_fault(:running, data), do: {:next_state, :recovering, data}
  defp transition_runtime_fault(:recovering, data), do: {:keep_state, data}
  defp transition_runtime_fault(_state, data), do: {:keep_state, data}

  defp maybe_restart_stopped_domains(%{runtime_faults: runtime_faults} = data) do
    Enum.reduce(runtime_faults, data, fn
      {{:domain, domain_id}, {:stopped, reason}}, acc ->
        restart_stopped_domain(acc, domain_id, reason)

      _other_fault, acc ->
        acc
    end)
  end

  defp retry_recovering_slaves(%{runtime_faults: runtime_faults} = data) do
    next_faults =
      Enum.reduce(runtime_faults, runtime_faults, fn
        {{:slave, name}, {:retreated, _target_state}}, acc ->
          retry_runtime_slave_request(acc, name)

        {{:slave, name}, {:preop, reason}}, acc ->
          if retryable_runtime_slave_fault?(reason) do
            retry_runtime_slave_request(acc, name)
          else
            acc
          end

        _other, acc ->
          acc
      end)

    %{data | runtime_faults: next_faults}
  end

  defp retry_runtime_slave_request(runtime_faults, name) do
    case Slave.request(name, :op) do
      :ok ->
        Map.delete(runtime_faults, {:slave, name})

      {:error, reason} ->
        Logger.warning(
          "[Master] recovery retry: #{inspect(name)} still not in :op: #{inspect(reason)}"
        )

        Map.put(runtime_faults, {:slave, name}, {:preop, reason})
    end
  end

  defp retryable_runtime_slave_fault?(
         {:preop_configuration_failed, {:domain_reregister_required, _, _}}
       ),
       do: false

  defp retryable_runtime_slave_fault?(_reason), do: true

  defp maybe_restart_dc_runtime(%{runtime_faults: runtime_faults} = data) do
    if Map.has_key?(runtime_faults, {:dc, :runtime}) and not dc_running?() and
         is_integer(data.dc_ref_station) do
      case start_dc_runtime(data) do
        {:ok, restarted_data} ->
          Logger.info("[Master] restarted DC runtime")
          clear_runtime_fault(restarted_data, {:dc, :runtime})

        {:error, reason} ->
          Logger.warning("[Master] failed to restart DC runtime: #{inspect(reason)}")
          data
      end
    else
      data
    end
  end

  defp restart_stopped_domain(data, domain_id, reason) do
    case Domain.start_cycling(domain_id) do
      :ok ->
        Logger.info(
          "[Master] restarted domain #{domain_id} after stop caused by #{inspect(reason)}"
        )

        data

      {:error, :already_cycling} ->
        data

      {:error, restart_reason} ->
        Logger.warning(
          "[Master] failed to restart domain #{domain_id} after stop: #{inspect(restart_reason)}"
        )

        data
    end
  end

  defp maybe_resume_running(data) do
    if map_size(data.activation_failures) == 0 and map_size(data.runtime_faults) == 0 do
      Logger.info("[Master] recovery succeeded; operational path is healthy again")
      {:ok, %{data | activation_failures: %{}, runtime_faults: %{}}}
    else
      {:recovering, data}
    end
  end

  defp degraded_reply(data) do
    activation_failures = data.activation_failures
    runtime_faults = data.runtime_faults

    cond do
      map_size(activation_failures) > 0 and map_size(runtime_faults) == 0 ->
        {:error, {:activation_failed, activation_failures}}

      map_size(activation_failures) == 0 and map_size(runtime_faults) > 0 ->
        {:error, {:runtime_degraded, runtime_faults}}

      true ->
        {:error,
         {:degraded, %{activation_failures: activation_failures, runtime_faults: runtime_faults}}}
    end
  end

  defp recovering_reply(%{runtime_faults: runtime_faults}) do
    {:error, {:runtime_degraded, runtime_faults}}
  end

  defp degraded_summary(data) do
    activation_count = map_size(data.activation_failures)
    runtime_count = map_size(data.runtime_faults)
    "activation_failures=#{activation_count} runtime_faults=#{runtime_count}"
  end

  defp recovering_summary(data) do
    "runtime_faults=#{map_size(data.runtime_faults)} activation_failures=#{map_size(data.activation_failures)}"
  end

  defp dc_status_for(%{dc_config: nil}) do
    %DCStatus{lock_state: :disabled}
  end

  defp dc_status_for(data) do
    base_status = %DCStatus{
      configured?: true,
      active?: false,
      cycle_ns: dc_cycle_ns(data),
      reference_station: data.dc_ref_station,
      reference_clock: reference_clock_name(data),
      lock_state: :inactive
    }

    if dc_running?() do
      case DC.status(dc_server()) do
        %DCStatus{} = status ->
          %{status | reference_clock: reference_clock_name(data)}

        {:error, _reason} ->
          base_status
      end
    else
      base_status
    end
  end

  defp reference_clock_name(%{dc_ref_station: nil}), do: nil

  defp reference_clock_name(data) do
    case Enum.find(data.slaves || [], fn {_name, station} ->
           station == data.dc_ref_station
         end) do
      {name, _station} -> name
      nil -> nil
    end
  end

  defp reference_clock_reply(%DCStatus{reference_station: station, reference_clock: name})
       when is_integer(station) do
    {:ok, %{name: name, station: station}}
  end

  defp reference_clock_reply(%DCStatus{configured?: false}), do: {:error, :dc_disabled}
  defp reference_clock_reply(_status), do: {:error, :no_reference_clock}

  defp reply_await_callers(callers, reply) do
    Enum.each(callers, fn from -> :gen_statem.reply(from, reply) end)
  end

  defp terminate_domain(domain_id) do
    case lookup_domain_pid(domain_id) do
      pid when is_pid(pid) -> DynamicSupervisor.terminate_child(EtherCAT.SessionSupervisor, pid)
      nil -> :ok
    end
  end

  defp safe_call(msg) do
    try do
      :gen_statem.call(__MODULE__, msg)
    catch
      :exit, {:noproc, _} -> {:error, :not_started}
    end
  end

  defp safe_call(msg, timeout) do
    try do
      :gen_statem.call(__MODULE__, msg, timeout)
    catch
      :exit, {:noproc, _} -> {:error, :not_started}
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  defp bus_server(_data), do: Bus

  defp bus_public_ref(_data) do
    if bus_running?(), do: bus_server(nil), else: nil
  end

  defp bus_running? do
    is_pid(Process.whereis(Bus))
  end

  defp dc_server, do: DC

  defp dc_running? do
    is_pid(Process.whereis(DC))
  end

  defp stop_bus do
    case Process.whereis(Bus) do
      pid when is_pid(pid) -> DynamicSupervisor.terminate_child(EtherCAT.SessionSupervisor, pid)
      nil -> :ok
    end
  end

  defp stop_dc_runtime do
    case Process.whereis(DC) do
      pid when is_pid(pid) -> DynamicSupervisor.terminate_child(EtherCAT.SessionSupervisor, pid)
      nil -> :ok
    end
  end

  defp maybe_demonitor_dc(ref) when is_reference(ref), do: Process.demonitor(ref, [:flush])
  defp maybe_demonitor_dc(_ref), do: :ok

  defp terminate_slave(name) do
    case lookup_slave_pid(name) do
      pid when is_pid(pid) -> DynamicSupervisor.terminate_child(EtherCAT.SlaveSupervisor, pid)
      nil -> :ok
    end
  end

  defp lookup_slave_pid(name) do
    case Registry.lookup(EtherCAT.Registry, {:slave, name}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp lookup_domain_pid(domain_id) do
    case Registry.lookup(EtherCAT.Registry, {:domain, domain_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp slave_server(name), do: {:via, Registry, {EtherCAT.Registry, {:slave, name}}}
end
