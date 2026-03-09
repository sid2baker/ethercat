defmodule EtherCAT.Master do
  @moduledoc false

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.{DC, Domain, Bus, Slave, Telemetry}
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Master.Activation
  alias EtherCAT.Master.Config
  alias EtherCAT.Master.Recovery
  alias EtherCAT.Master.Session
  alias EtherCAT.Master.Startup
  alias EtherCAT.Master.Status
  alias EtherCAT.Slave.Registers

  @base_station 0x1000

  # Scanning: poll every 100 ms, require 1 s of stable identical readings
  @scan_poll_ms 100
  @scan_stable_ms 1_000

  # Configuring: 30 s to receive :preop notifications from all slaves
  @configuring_timeout_ms 30_000

  @degraded_retry_ms 1_000

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

  @doc """
  Return the last terminal startup/runtime failure retained after the master
  returned to `:idle`.
  """
  @spec last_failure() :: map() | nil | {:error, :not_started}
  def last_failure, do: safe_call(:last_failure)

  @doc """
  Return the current session phase.

  This is the public lifecycle view and distinguishes between PREOP-ready
  startup, degraded activation, fully operational cyclic runtime, and runtime
  recovery.
  """
  @spec phase() ::
          :idle
          | :scanning
          | :configuring
          | :preop_ready
          | :operational
          | :degraded
          | :recovering
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
  Returns `{:error, {:activation_failed, failures}}` or
  `{:error, {:runtime_degraded, faults}}` when the current session is not
  usable.
  """
  @spec await_running(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_running(timeout_ms \\ 10_000) do
    safe_call(:await_running, timeout_ms)
  end

  @doc """
  Block until the master reaches operational cyclic runtime, then return `:ok`.

  This waits for DC/domain runtime to start and for `:op` promotion to complete.
  Returns `{:error, :not_started}` if the master is idle or not running.
  Returns `{:error, {:activation_failed, failures}}` for startup degradations,
  `{:error, {:runtime_degraded, faults}}` while runtime recovery is in progress,
  and `{:error, :timeout}` if the deadline expires first.
  """
  @spec await_operational(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_operational(timeout_ms \\ 10_000) do
    safe_call(:await_operational, timeout_ms)
  end

  @doc """
  Return a Distributed Clocks status snapshot for the current session.

  The returned `%EtherCAT.DC.Status{}` includes both:

  - activation-time lock gating via `await_lock?`
  - runtime lock-loss behavior via `lock_policy`
  """
  @spec dc_status() :: EtherCAT.DC.Status.t() | {:error, :not_started}
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
    {:keep_state_and_data, [{:reply, from, Status.dc_status(data)}]}
  end

  def handle_event({:call, from}, :reference_clock, :idle, data) do
    {:keep_state_and_data, [{:reply, from, Status.reference_clock_reply(Status.dc_status(data))}]}
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
      Startup.tune_bus_frame_timeout(data, slave_count)
      Logger.info("[Master] bus stable — #{slave_count} slave(s)")
      config_data = %{data | scan_window: [], slave_count: slave_count}

      case Startup.configure_network(config_data) do
        {:ok, configured} ->
          if MapSet.size(configured.pending_preop) == 0 do
            Logger.info("[Master] all slaves in :preop — activating")

            case Activation.activate_network(configured) do
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

      case Activation.activate_network(%{data | pending_preop: new_pending}) do
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
    case Activation.activate_network(data) do
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
    Logger.warning("[Master] degraded — #{Status.degraded_summary(data)}")

    reply_await_callers(data.await_callers, Status.degraded_reply(data))
    reply_await_callers(data.await_operational_callers, Status.degraded_reply(data))

    {:keep_state, %{data | await_callers: [], await_operational_callers: []},
     [{{:timeout, :degraded_retry}, @degraded_retry_ms, nil}]}
  end

  def handle_event({:timeout, :degraded_retry}, nil, :degraded, data) do
    case Recovery.retry_degraded_state(data) do
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
    {:keep_state_and_data, [{:reply, from, Status.degraded_reply(data)}]}
  end

  def handle_event({:call, from}, :await_operational, :degraded, data) do
    {:keep_state_and_data, [{:reply, from, Status.degraded_reply(data)}]}
  end

  def handle_event({:call, from}, {:configure_slave, _slave_name, _spec}, :degraded, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :activation_in_progress}}]}
  end

  def handle_event({:call, from}, :activate, :degraded, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :activation_in_progress}}]}
  end

  # :recovering --------------------------------------------------------------

  def handle_event(:enter, _old, :recovering, data) do
    Logger.warning("[Master] recovering — #{Status.recovering_summary(data)}")

    reply_await_callers(data.await_callers, Status.recovering_reply(data))
    reply_await_callers(data.await_operational_callers, Status.recovering_reply(data))

    {:keep_state, %{data | await_callers: [], await_operational_callers: []},
     [{{:timeout, :degraded_retry}, @degraded_retry_ms, nil}]}
  end

  def handle_event({:timeout, :degraded_retry}, nil, :recovering, data) do
    case Recovery.retry_recovering_state(data) do
      {:ok, healed_data} ->
        {:next_state, :running, healed_data}

      {:recovering, still_recovering} ->
        case Recovery.unrecoverable_recovery_reason(still_recovering) do
          nil ->
            {:keep_state, still_recovering,
             [{{:timeout, :degraded_retry}, @degraded_retry_ms, nil}]}

          reason ->
            Logger.error("[Master] recovery failed and requires full restart: #{inspect(reason)}")

            stop_session(still_recovering)

            {:next_state, :idle, reset_master(failure_snapshot(:recovery_unrecoverable, reason))}
        end
    end
  end

  def handle_event({:call, from}, :stop, :recovering, data) do
    stop_session(data)
    reply_await_callers(data.await_operational_callers, {:error, :stopped})
    {:next_state, :idle, reset_master(data.last_failure), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, :recovering, data) do
    {:keep_state_and_data, [{:reply, from, Status.recovering_reply(data)}]}
  end

  def handle_event({:call, from}, :await_operational, :recovering, data) do
    {:keep_state_and_data, [{:reply, from, Status.recovering_reply(data)}]}
  end

  def handle_event({:call, from}, {:configure_slave, _slave_name, _spec}, :recovering, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :recovery_in_progress}}]}
  end

  def handle_event({:call, from}, :activate, :recovering, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :recovery_in_progress}}]}
  end

  # -- Shared handlers (all non-idle states) ---------------------------------

  # Query handlers — work in all active states
  def handle_event({:call, from}, :phase, state, data) do
    {:keep_state_and_data, [{:reply, from, Status.phase(state, data)}]}
  end

  def handle_event({:call, from}, :last_failure, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.last_failure}]}
  end

  def handle_event({:call, from}, :dc_status, _state, data) do
    {:keep_state_and_data, [{:reply, from, Status.dc_status(data)}]}
  end

  def handle_event({:call, from}, :reference_clock, _state, data) do
    {:keep_state_and_data, [{:reply, from, Status.reference_clock_reply(Status.dc_status(data))}]}
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
    {:keep_state_and_data, [{:reply, from, Status.slaves(data)}]}
  end

  def handle_event({:call, from}, :domains, _state, data) do
    {:keep_state_and_data, [{:reply, from, Status.domains(data)}]}
  end

  def handle_event({:call, from}, :bus, _state, data) do
    {:keep_state_and_data, [{:reply, from, Status.bus_public_ref(data)}]}
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

    recovering_data =
      Recovery.put_runtime_fault(data_with_refs, {:domain, id}, {:crashed, reason})

    Recovery.transition_runtime_fault(state, recovering_data)
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
      |> Recovery.put_runtime_fault({:slave, name}, {:crashed, reason})

    Recovery.transition_runtime_fault(state, recovering_data)
  end

  # DC runtime crashed unexpectedly
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, state, data)
      when ref == data.dc_ref and not is_nil(ref) do
    Logger.error("[Master] DC runtime crashed: #{inspect(reason)}")

    recovering_data =
      data
      |> Map.put(:dc_ref, nil)
      |> Recovery.put_runtime_fault({:dc, :runtime}, {:crashed, reason})

    Recovery.transition_runtime_fault(state, recovering_data)
  end

  # Stale :DOWN from a previous session — ignore
  def handle_event(:info, {:DOWN, _ref, :process, _pid, _reason}, _state, _data) do
    :keep_state_and_data
  end

  # Domain stopped cycling due to consecutive misses
  def handle_event(:info, {:domain_stopped, id, reason}, state, data) do
    Logger.error("[Master] domain #{id} stopped cycling: #{inspect(reason)}")
    recovering_data = Recovery.put_runtime_fault(data, {:domain, id}, {:stopped, reason})
    Recovery.transition_runtime_fault(state, recovering_data)
  end

  def handle_event(:info, {:domain_cycle_invalid, id, reason}, :running, data) do
    Logger.warning("[Master] domain #{id} cycle invalid: #{inspect(reason)} — entering recovery")

    {:next_state, :recovering,
     Recovery.put_runtime_fault(data, {:domain, id}, {:cycle_invalid, reason})}
  end

  def handle_event(:info, {:domain_cycle_invalid, id, reason}, :recovering, data) do
    Logger.warning("[Master] domain #{id} cycle still invalid: #{inspect(reason)}")
    {:keep_state, Recovery.put_runtime_fault(data, {:domain, id}, {:cycle_invalid, reason})}
  end

  def handle_event(:info, {:domain_cycle_invalid, _id, _reason}, _state, _data) do
    :keep_state_and_data
  end

  def handle_event(:info, {:domain_cycle_recovered, id}, :recovering, data) do
    Logger.info("[Master] domain #{id} cycle recovered")

    case Recovery.maybe_resume_running(Recovery.clear_runtime_fault(data, {:domain, id})) do
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
     Recovery.put_runtime_fault(data, {:slave, name}, {:retreated, target_state})}
  end

  def handle_event(:info, {:slave_retreated, name, target_state}, :recovering, data) do
    Logger.warning("[Master] slave #{name} retreated to #{target_state} (already recovering)")
    {:keep_state, Recovery.put_runtime_fault(data, {:slave, name}, {:retreated, target_state})}
  end

  def handle_event(:info, {:slave_retreated, name, target_state}, _state, _data) do
    Logger.warning("[Master] slave #{name} retreated to #{target_state} (already not running)")
    :keep_state_and_data
  end

  # Slave physically disconnected (health poll wkc=0 or bus error)
  def handle_event(:info, {:slave_down, name}, :running, data) do
    Logger.warning("[Master] slave #{name} disconnected — entering recovery")

    {:next_state, :recovering,
     Recovery.put_runtime_fault(data, {:slave, name}, {:down, :disconnected})}
  end

  def handle_event(:info, {:slave_down, name}, :recovering, data) do
    Logger.warning("[Master] slave #{name} disconnected (already recovering)")
    {:keep_state, Recovery.put_runtime_fault(data, {:slave, name}, {:down, :disconnected})}
  end

  def handle_event(:info, {:slave_reconnected, name}, :recovering, data) do
    Logger.info("[Master] slave #{name} link restored — authorizing reconnect")

    case Slave.authorize_reconnect(name) do
      :ok ->
        {:keep_state,
         Recovery.put_runtime_fault(data, {:slave, name}, {:reconnecting, :authorized})}

      {:error, reason} ->
        Logger.warning(
          "[Master] slave #{name} reconnect authorization failed: #{inspect(reason)}"
        )

        {:keep_state,
         Recovery.put_runtime_fault(data, {:slave, name}, {:reconnect_failed, reason})}
    end
  end

  # Slave reconnected and reached :preop — attempt to bring it back to :op
  def handle_event(:info, {:slave_ready, name, :preop}, :recovering, data) do
    Logger.info("[Master] slave #{name} reconnected and in :preop — requesting :op")

    case Slave.request(name, :op) do
      :ok ->
        recovered_data =
          data
          |> Recovery.clear_runtime_fault({:slave, name})
          |> Recovery.maybe_restart_stopped_domains()
          |> Recovery.maybe_restart_dc_runtime()

        case Recovery.maybe_resume_running(recovered_data) do
          {:ok, healed_data} ->
            {:next_state, :running, healed_data}

          {:recovering, still_recovering} ->
            {:keep_state, still_recovering}
        end

      {:error, reason} ->
        Logger.warning(
          "[Master] slave #{name} :op request failed after reconnect: #{inspect(reason)}"
        )

        {:keep_state, Recovery.put_runtime_fault(data, {:slave, name}, {:preop, reason})}
    end
  end

  def handle_event(:info, {:dc_runtime_failed, reason}, :running, data) do
    Logger.warning("[Master] DC runtime failed: #{inspect(reason)} — entering recovery")

    {:next_state, :recovering,
     Recovery.put_runtime_fault(data, {:dc, :runtime}, {:failed, reason})}
  end

  def handle_event(:info, {:dc_runtime_failed, reason}, :recovering, data) do
    Logger.warning("[Master] DC runtime still failing: #{inspect(reason)}")
    {:keep_state, Recovery.put_runtime_fault(data, {:dc, :runtime}, {:failed, reason})}
  end

  def handle_event(:info, {:dc_runtime_recovered}, :recovering, data) do
    Logger.info("[Master] DC runtime recovered")

    case Recovery.maybe_resume_running(Recovery.clear_runtime_fault(data, {:dc, :runtime})) do
      {:ok, healed_data} ->
        {:next_state, :running, healed_data}

      {:recovering, still_recovering} ->
        {:keep_state, still_recovering}
    end
  end

  def handle_event(:info, {:dc_lock_lost, lock_state, max_sync_diff_ns}, :running, data)
      when not is_nil(data.dc_config) do
    case Recovery.lock_policy(data) do
      :advisory ->
        Logger.warning(
          "[Master] DC lock lost: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — advisory only"
        )

        :keep_state_and_data

      :recovering ->
        Logger.warning(
          "[Master] DC lock lost: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — entering recovery"
        )

        {:next_state, :recovering,
         Recovery.put_runtime_fault(data, {:dc, :lock}, {lock_state, max_sync_diff_ns})}

      :fatal ->
        Logger.error(
          "[Master] DC lock lost: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — stopping session"
        )

        stop_session(data)

        {:next_state, :idle,
         reset_master(failure_snapshot(:dc_lock_lost, {lock_state, max_sync_diff_ns}))}
    end
  end

  def handle_event(:info, {:dc_lock_lost, _lock_state, _max_sync_diff_ns}, :running, _data) do
    :keep_state_and_data
  end

  def handle_event(:info, {:dc_lock_lost, lock_state, max_sync_diff_ns}, :recovering, data)
      when not is_nil(data.dc_config) do
    case Recovery.lock_policy(data) do
      :advisory ->
        Logger.warning(
          "[Master] DC lock lost while recovering: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — advisory only"
        )

        :keep_state_and_data

      :recovering ->
        Logger.warning(
          "[Master] DC lock still lost: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)}"
        )

        {:keep_state,
         Recovery.put_runtime_fault(data, {:dc, :lock}, {lock_state, max_sync_diff_ns})}

      :fatal ->
        Logger.error(
          "[Master] DC lock lost while recovering: state=#{inspect(lock_state)} max_sync_diff_ns=#{inspect(max_sync_diff_ns)} — stopping session"
        )

        stop_session(data)

        {:next_state, :idle,
         reset_master(failure_snapshot(:dc_lock_lost, {lock_state, max_sync_diff_ns}))}
    end
  end

  def handle_event(:info, {:dc_lock_lost, _lock_state, _max_sync_diff_ns}, :recovering, _data) do
    :keep_state_and_data
  end

  def handle_event(:info, {:dc_lock_regained, max_sync_diff_ns}, :running, data)
      when not is_nil(data.dc_config) do
    case Recovery.lock_policy(data) do
      :advisory ->
        Logger.info("[Master] DC lock regained (max_sync_diff_ns=#{inspect(max_sync_diff_ns)})")
        :keep_state_and_data

      :recovering ->
        :keep_state_and_data

      :fatal ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:dc_lock_regained, _max_sync_diff_ns}, :running, _data) do
    :keep_state_and_data
  end

  def handle_event(:info, {:dc_lock_regained, max_sync_diff_ns}, :recovering, data)
      when not is_nil(data.dc_config) do
    case Recovery.lock_policy(data) do
      :advisory ->
        Logger.info(
          "[Master] DC lock regained while recovering (max_sync_diff_ns=#{inspect(max_sync_diff_ns)})"
        )

        :keep_state_and_data

      :recovering ->
        Logger.info("[Master] DC lock regained (max_sync_diff_ns=#{inspect(max_sync_diff_ns)})")

        case Recovery.maybe_resume_running(Recovery.clear_runtime_fault(data, {:dc, :lock})) do
          {:ok, healed_data} ->
            {:next_state, :running, healed_data}

          {:recovering, still_recovering} ->
            {:keep_state, still_recovering}
        end

      :fatal ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:dc_lock_regained, _max_sync_diff_ns}, :recovering, _data) do
    :keep_state_and_data
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

  # -- Session teardown ------------------------------------------------------

  defp stop_session(data) do
    Session.stop(data)
  end

  defp reply_await_callers(callers, reply) do
    Enum.each(callers, fn from -> :gen_statem.reply(from, reply) end)
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

  defp dc_server, do: DC

  defp dc_running? do
    is_pid(Process.whereis(DC))
  end
end
