defmodule EtherCAT.Master do
  @moduledoc """
  EtherCAT master — singleton gen_statem registered as `EtherCAT.Master`.

  ## States

    - `:idle` — not started
    - `:scanning` — bus open, polling for a stable slave count
    - `:configuring` — stations assigned, DC initialised, slaves spawned;
      waiting for all named slaves to reach `:preop`
    - `:running` — startup finished; either operational or waiting for explicit activation
    - `:degraded` — startup completed partially; failed slave promotions are retried

  The state machine is fully self-driving for static startup. For dynamic startup,
  call `configure_slave/2` while discovered slaves are held in PREOP, then call
  `activate/0` to start cyclic operation.

  ## Example

      EtherCAT.start(
        interface: "eth0",
        domains: [%EtherCAT.Domain.Config{id: :main, period_ms: 1}],
        slaves: [
          %EtherCAT.Slave.Config{name: :coupler},
          %EtherCAT.Slave.Config{
            name: :sensor,
            driver: MyApp.EL1809,
            process_data: {:all, :main}
          },
          %EtherCAT.Slave.Config{
            name: :valve,
            driver: MyApp.EL2809,
            process_data: {:all, :main}
          }
        ]
      )
      :ok = EtherCAT.await_running()

  Station addresses are assigned from list position: `base_station + index`.
  When `slaves: []` (or omitted), the master starts one dynamic default slave per
  discovered station and leaves them in `:preop` for runtime configuration.
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.{DC, Domain, Bus, Slave}
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Slave.Driver.Default, as: DefaultSlaveDriver
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
  @init_poll_limit 50
  @init_poll_interval_ms 10

  @master_option_keys [:slaves, :domains, :base_station, :dc_cycle_ns, :frame_timeout_ms]

  defstruct [
    :bus_pid,
    :bus_ref,
    :dc_pid,
    # station address of the DC reference clock slave (nil if no DC)
    :dc_ref_station,
    :domain_config,
    :slave_config,
    :dc_cycle_ns,
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
    # blocked await_running callers — replied when :running is entered
    await_callers: [],
    # blocked await_operational callers — replied when cyclic operation is live
    await_operational_callers: []
  ]

  # -- Public API ------------------------------------------------------------

  @doc """
  Start the master: open a bus and begin scanning for slaves.

  Options:
    - `:interface` (required) — e.g. `"eth0"`
    - `:slaves` — list of slave config entries, default `[]`. Each entry is a
      `%EtherCAT.Slave.Config{}` (or equivalent keyword list) with keys: `:name`, `:driver`,
      `:config`, `:process_data`, and `:target_state`. `process_data` declares what
      the slave should register while in PREOP:
      - `:none`
      - `{:all, domain_id}`
      - `[{pdo_name, domain_id}]`
      `target_state` is `:op` or `:preop`. `nil` entries are rejected. If omitted,
      dynamic default slaves are started for all discovered stations and held in
      `:preop` for runtime configuration.
    - `:domains` — list of domain specs, default `[]`. Each entry is a keyword list with
      keys `:id` (atom, required) and `:period_ms` (required), plus any Domain options
    - `:base_station` — starting station address, default `0x1000`
    - `:dc_cycle_ns` — SYNC0 cycle time in ns for DC-capable slaves (default `1_000_000`)
    - `:frame_timeout_ms` — optional fixed bus frame response timeout (ms); if omitted,
      master auto-tunes from slave count + cycle time
    - any other option is forwarded to `Bus.start_link/1` unchanged
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: :gen_statem.call(__MODULE__, {:start, opts})

  @doc "Stop the master: shut down all slaves, domains, and the bus."
  @spec stop() :: :ok
  def stop, do: :gen_statem.call(__MODULE__, :stop)

  @doc "Return `[{name, station, pid}]` for all named slaves."
  @spec slaves() :: list()
  def slaves, do: :gen_statem.call(__MODULE__, :slaves)

  @doc "Return the bus pid."
  @spec bus() :: pid() | nil
  def bus, do: :gen_statem.call(__MODULE__, :bus)

  @doc "Return the current master state atom."
  @spec state() :: atom()
  def state, do: :gen_statem.call(__MODULE__, :state)

  @doc """
  Return the current session phase.

  Unlike `state/0`, this is the public lifecycle view and distinguishes between
  PREOP-ready startup and fully operational cyclic runtime.
  """
  @spec phase() :: :idle | :scanning | :configuring | :preop_ready | :operational | :degraded
  def phase, do: :gen_statem.call(__MODULE__, :phase)

  @doc """
  Configure a discovered slave while the session is still in PREOP.

  Keyword-list updates merge into the current config. `%EtherCAT.Slave.Config{}`
  replaces the current declarative config for that slave.
  """
  @spec configure_slave(atom(), keyword() | EtherCAT.Slave.Config.t()) :: :ok | {:error, term()}
  def configure_slave(slave_name, spec) do
    :gen_statem.call(__MODULE__, {:configure_slave, slave_name, spec})
  end

  @doc """
  Start cyclic operation after dynamic PREOP configuration.

  This starts DC runtime, starts all domains cycling, and advances every slave
  whose `target_state` is `:op`.
  """
  @spec activate() :: :ok | {:error, term()}
  def activate do
    :gen_statem.call(__MODULE__, :activate)
  end

  @doc """
  Block until the master reaches `:running`, then return `:ok`.

  Returns immediately if already `:running`. Returns `{:error, :timeout}` if
  the master does not reach `:running` within `timeout_ms` milliseconds.
  Returns `{:error, :not_started}` if the master is `:idle`.
  """
  @spec await_running(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_running(timeout_ms \\ 10_000) do
    :gen_statem.call(__MODULE__, :await_running, timeout_ms)
  end

  @doc """
  Block until the master reaches operational cyclic runtime, then return `:ok`.

  This waits for DC/domain runtime to start and for `:op` promotion to complete.
  Returns `{:error, :not_started}` if the master is idle.
  Returns `{:error, {:activation_failed, failures}}` if activation falls into degraded mode.
  """
  @spec await_operational(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_operational(timeout_ms \\ 10_000) do
    :gen_statem.call(__MODULE__, :await_operational, timeout_ms)
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
        | bus_pid: bus_pid,
          bus_ref: bus_ref,
          base_station: start_config.base_station,
          slave_config: start_config.slave_config,
          domain_config: start_config.domain_config,
          dc_cycle_ns: start_config.dc_cycle_ns,
          frame_timeout_override_ms: start_config.frame_timeout_override_ms,
          activation_phase: :preop_ready,
          activatable_slaves: [],
          slaves: [],
          scan_window: [],
          pending_preop: MapSet.new(),
          activation_failures: %{},
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

  def handle_event({:call, from}, :phase, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, :idle}]}
  end

  def handle_event({:call, from}, :await_running, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_started}}]}
  end

  def handle_event({:call, from}, :await_operational, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_started}}]}
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
      case Bus.transaction(data.bus_pid, Transaction.brd(Registers.esc_type())) do
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

                {:next_state, :idle, %__MODULE__{}}
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

          {:next_state, :idle, %__MODULE__{}}
      end
    else
      {:keep_state, %{data | scan_window: new_window},
       [{{:timeout, :scan_poll}, @scan_poll_ms, nil}]}
    end
  end

  def handle_event({:call, from}, :stop, :scanning, data) do
    stop_session(data)
    reply_await_callers(data.await_operational_callers, {:error, :stopped})
    {:next_state, :idle, %__MODULE__{}, [{:reply, from, :ok}]}
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

          {:next_state, :idle, %__MODULE__{}, [{{:timeout, :configuring}, :cancel}]}
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
    {:next_state, :idle, %__MODULE__{}}
  end

  def handle_event({:call, from}, :stop, :configuring, data) do
    stop_session(data)
    reply_await_callers(data.await_callers, {:error, :stopped})
    reply_await_callers(data.await_operational_callers, {:error, :stopped})
    {:next_state, :idle, %__MODULE__{}, [{:reply, from, :ok}]}
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
    {:next_state, :idle, %__MODULE__{}, [{:reply, from, :ok}]}
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
    Logger.warning("[Master] degraded startup; retrying failed slave promotions")

    reply_await_callers(
      data.await_callers,
      {:error, {:activation_failed, data.activation_failures}}
    )

    reply_await_callers(
      data.await_operational_callers,
      {:error, {:activation_failed, data.activation_failures}}
    )

    {:keep_state, %{data | await_callers: [], await_operational_callers: []},
     [{{:timeout, :degraded_retry}, @degraded_retry_ms, nil}]}
  end

  def handle_event({:timeout, :degraded_retry}, nil, :degraded, data) do
    case retry_failed_activation(data) do
      {:ok, healed_data} ->
        {:next_state, :running, healed_data}

      {:degraded, still_degraded} ->
        {:keep_state, still_degraded, [{{:timeout, :degraded_retry}, @degraded_retry_ms, nil}]}
    end
  end

  def handle_event({:call, from}, :stop, :degraded, data) do
    stop_session(data)
    reply_await_callers(data.await_operational_callers, {:error, :stopped})
    {:next_state, :idle, %__MODULE__{}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, :degraded, data) do
    {:keep_state_and_data,
     [{:reply, from, {:error, {:activation_failed, data.activation_failures}}}]}
  end

  def handle_event({:call, from}, :await_operational, :degraded, data) do
    {:keep_state_and_data,
     [{:reply, from, {:error, {:activation_failed, data.activation_failures}}}]}
  end

  def handle_event({:call, from}, {:configure_slave, _slave_name, _spec}, :degraded, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :activation_in_progress}}]}
  end

  def handle_event({:call, from}, :activate, :degraded, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :activation_in_progress}}]}
  end

  # -- Shared handlers (all non-idle states) ---------------------------------

  # Query handlers — work in all active states
  def handle_event({:call, from}, :state, state, _data) do
    {:keep_state_and_data, [{:reply, from, state}]}
  end

  def handle_event({:call, from}, :phase, state, data) do
    {:keep_state_and_data, [{:reply, from, phase_for(state, data)}]}
  end

  def handle_event({:call, from}, :slaves, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.slaves}]}
  end

  def handle_event({:call, from}, :bus, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.bus_pid}]}
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
    stop_session(%{data | bus_pid: nil})
    {:next_state, :idle, %__MODULE__{}}
  end

  # Stale :DOWN from a previous session — ignore
  def handle_event(:info, {:DOWN, _ref, :process, _pid, _reason}, _state, _data) do
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

  defp normalize_start_options(opts) when is_list(opts) do
    slave_config = Keyword.get(opts, :slaves, [])
    domain_config = Keyword.get(opts, :domains, [])
    frame_timeout_override_ms = Keyword.get(opts, :frame_timeout_ms)

    with {:ok, _interface} <- Keyword.fetch(opts, :interface),
         :ok <- validate_slave_start_config(slave_config) do
      {:ok,
       %{
         base_station: Keyword.get(opts, :base_station, @base_station),
         bus_opts: build_bus_start_opts(opts, frame_timeout_override_ms),
         dc_cycle_ns: Keyword.get(opts, :dc_cycle_ns, 1_000_000),
         domain_config: domain_config,
         slave_config: slave_config,
         frame_timeout_override_ms: frame_timeout_override_ms
       }}
    else
      :error -> {:error, :missing_interface}
      {:error, _} = err -> err
    end
  end

  defp normalize_start_options(_opts), do: {:error, :invalid_start_options}

  defp build_bus_start_opts(opts, frame_timeout_override_ms) do
    opts
    |> Keyword.drop(@master_option_keys)
    |> Keyword.put_new(:name, EtherCAT.Bus)
    |> maybe_put_frame_timeout(frame_timeout_override_ms)
  end

  defp start_session_bus(bus_opts) do
    DynamicSupervisor.start_child(EtherCAT.SessionSupervisor, {Bus, bus_opts})
  end

  defp validate_slave_start_config(slave_config) when is_list(slave_config) do
    case Enum.find_index(slave_config, &is_nil/1) do
      idx when is_integer(idx) ->
        {:error, {:invalid_slave_config, {:nil_entry, idx}}}

      nil ->
        case Enum.find_index(slave_config, fn entry ->
               not (is_list(entry) or is_struct(entry, EtherCAT.Slave.Config))
             end) do
          idx when is_integer(idx) ->
            {:error, {:invalid_slave_config, {:invalid_entry, idx}}}

          nil ->
            case find_invalid_slave_entry(slave_config) do
              {idx, reason} -> {:error, {:invalid_slave_config, {:invalid_options, idx, reason}}}
              nil -> :ok
            end
        end
    end
  end

  defp validate_slave_start_config(_), do: {:error, {:invalid_slave_config, :invalid_list}}

  defp find_invalid_slave_entry(slave_config) do
    Enum.with_index(slave_config)
    |> Enum.find_value(fn {entry, idx} ->
      case validate_slave_entry(entry) do
        :ok -> nil
        {:error, reason} -> {idx, reason}
      end
    end)
  end

  defp validate_slave_entry(%EtherCAT.Slave.Config{} = cfg) do
    validate_slave_options(cfg.process_data, cfg.target_state)
  end

  defp validate_slave_entry(opts) when is_list(opts) do
    validate_slave_options(
      Keyword.get(opts, :process_data, :none),
      Keyword.get(opts, :target_state, :op)
    )
  end

  defp validate_slave_options(process_data, target_state) do
    with :ok <- validate_process_data_request(process_data),
         :ok <- validate_target_state(target_state) do
      :ok
    end
  end

  defp validate_process_data_request(:none), do: :ok

  defp validate_process_data_request({:all, domain_id}) when is_atom(domain_id), do: :ok

  defp validate_process_data_request(requested_pdos) when is_list(requested_pdos) do
    if Enum.all?(requested_pdos, &valid_requested_pdo?/1) do
      :ok
    else
      {:error, :invalid_process_data}
    end
  end

  defp validate_process_data_request(_process_data), do: {:error, :invalid_process_data}

  defp validate_target_state(:op), do: :ok
  defp validate_target_state(:preop), do: :ok
  defp validate_target_state(_target_state), do: {:error, :invalid_target_state}

  defp valid_requested_pdo?({pdo_name, domain_id}) when is_atom(pdo_name) and is_atom(domain_id),
    do: true

  defp valid_requested_pdo?(_), do: false

  defp normalize_domain_config(%EtherCAT.Domain.Config{} = cfg) do
    [
      id: cfg.id,
      period_ms: cfg.period_ms,
      miss_threshold: cfg.miss_threshold,
      logical_base: cfg.logical_base
    ]
  end

  defp normalize_domain_config(opts) when is_list(opts), do: opts

  defp normalize_slave_config(%EtherCAT.Slave.Config{} = cfg) do
    [
      name: cfg.name,
      driver: normalize_slave_driver(cfg.driver),
      config: cfg.config,
      process_data: cfg.process_data,
      target_state: normalize_slave_target_state(cfg.target_state)
    ]
  end

  defp normalize_slave_config(opts) when is_list(opts) do
    [
      name: Keyword.fetch!(opts, :name),
      driver: normalize_slave_driver(Keyword.get(opts, :driver)),
      config: Keyword.get(opts, :config, %{}),
      process_data: Keyword.get(opts, :process_data, :none),
      target_state: normalize_slave_target_state(Keyword.get(opts, :target_state, :op))
    ]
  end

  defp normalize_slave_driver(nil), do: DefaultSlaveDriver
  defp normalize_slave_driver(driver), do: driver

  defp normalize_slave_target_state(:op), do: :op
  defp normalize_slave_target_state(:preop), do: :preop

  defp normalize_runtime_slave_config(
         slave_name,
         %EtherCAT.Slave.Config{} = cfg,
         _current_config
       ) do
    if cfg.name not in [nil, slave_name] do
      {:error, :name_mismatch}
    else
      normalized = [
        name: slave_name,
        driver: normalize_slave_driver(cfg.driver),
        config: cfg.config,
        process_data: cfg.process_data,
        target_state: normalize_slave_target_state(cfg.target_state)
      ]

      validate_runtime_slave_config(normalized)
    end
  end

  defp normalize_runtime_slave_config(slave_name, opts, current_config) when is_list(opts) do
    normalized = [
      name: slave_name,
      driver:
        normalize_slave_driver(
          Keyword.get(opts, :driver, Keyword.fetch!(current_config, :driver))
        ),
      config: Keyword.get(opts, :config, Keyword.fetch!(current_config, :config)),
      process_data:
        Keyword.get(opts, :process_data, Keyword.fetch!(current_config, :process_data)),
      target_state:
        normalize_slave_target_state(
          Keyword.get(opts, :target_state, Keyword.fetch!(current_config, :target_state))
        )
    ]

    validate_runtime_slave_config(normalized)
  end

  defp normalize_runtime_slave_config(_slave_name, _spec, _current_config) do
    {:error, :invalid_slave_config_update}
  end

  defp validate_runtime_slave_config(normalized) do
    case validate_slave_options(
           Keyword.fetch!(normalized, :process_data),
           Keyword.fetch!(normalized, :target_state)
         ) do
      :ok -> {:ok, normalized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dynamic_slave_configs(0), do: []

  defp dynamic_slave_configs(bus_count) do
    Enum.map(0..(bus_count - 1), fn pos ->
      [
        name: dynamic_slave_name(pos),
        driver: DefaultSlaveDriver,
        config: %{},
        process_data: :none,
        target_state: :preop
      ]
    end)
  end

  defp dynamic_slave_name(0), do: :coupler
  defp dynamic_slave_name(pos), do: :"slave_#{pos}"

  defp configure_discovered_slave(%{activation_phase: :operational}, _slave_name, _spec) do
    {:error, :activation_already_started}
  end

  defp configure_discovered_slave(data, slave_name, spec) do
    with {:ok, current_config, config_idx} <-
           fetch_slave_config(data.slave_config || [], slave_name),
         {:ok, normalized_config} <-
           normalize_runtime_slave_config(slave_name, spec, current_config),
         :ok <- ensure_known_domains(data, normalized_config),
         :ok <- ensure_slave_in_preop(slave_name),
         :ok <- maybe_apply_slave_configuration(slave_name, current_config, normalized_config) do
      updated_slave_config = List.replace_at(data.slave_config, config_idx, normalized_config)

      {:ok,
       %{
         data
         | slave_config: updated_slave_config,
           activatable_slaves: activatable_slave_names(updated_slave_config)
       }}
    end
  end

  defp fetch_slave_config(slave_config, slave_name) do
    case Enum.find_index(slave_config, fn entry ->
           Keyword.fetch!(normalize_slave_config(entry), :name) == slave_name
         end) do
      nil ->
        {:error, {:unknown_slave, slave_name}}

      idx ->
        {:ok, normalize_slave_config(Enum.at(slave_config, idx)), idx}
    end
  end

  defp ensure_known_domains(data, slave_config) do
    known_domains = MapSet.new(get_domain_ids(data.domain_config || []))

    unknown_domains =
      slave_config
      |> Keyword.fetch!(:process_data)
      |> requested_domain_ids()
      |> Enum.reject(&MapSet.member?(known_domains, &1))

    case unknown_domains do
      [] -> :ok
      domains -> {:error, {:unknown_domains, domains}}
    end
  end

  defp requested_domain_ids(:none), do: []
  defp requested_domain_ids({:all, domain_id}), do: [domain_id]

  defp requested_domain_ids(requested_pdos) when is_list(requested_pdos) do
    requested_pdos
    |> Enum.map(fn {_pdo_name, domain_id} -> domain_id end)
    |> Enum.uniq()
  end

  defp ensure_slave_in_preop(slave_name) do
    case Slave.state(slave_name) do
      :preop -> :ok
      state -> {:error, {:not_preop, state}}
    end
  end

  defp maybe_apply_slave_configuration(slave_name, current_config, updated_config) do
    if slave_local_config(current_config) == slave_local_config(updated_config) do
      :ok
    else
      Slave.configure(
        slave_name,
        driver: Keyword.fetch!(updated_config, :driver),
        config: Keyword.fetch!(updated_config, :config),
        process_data: Keyword.fetch!(updated_config, :process_data)
      )
    end
  end

  defp slave_local_config(config) do
    [
      driver: Keyword.fetch!(config, :driver),
      config: Keyword.fetch!(config, :config),
      process_data: Keyword.fetch!(config, :process_data)
    ]
  end

  defp activatable_slave_names(slave_config) do
    Enum.reduce(slave_config, [], fn entry, acc ->
      normalized = normalize_slave_config(entry)

      if Keyword.fetch!(normalized, :target_state) == :op do
        [Keyword.fetch!(normalized, :name) | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp maybe_put_frame_timeout(opts, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    Keyword.put(opts, :frame_timeout_ms, timeout_ms)
  end

  defp maybe_put_frame_timeout(opts, _timeout_ms), do: opts

  defp tune_bus_frame_timeout(%{bus_pid: nil}, _slave_count), do: :ok

  defp tune_bus_frame_timeout(data, slave_count) do
    target_ms = recommended_frame_timeout_ms(data, slave_count)

    case Bus.set_frame_timeout(data.bus_pid, target_ms) do
      :ok ->
        Logger.info(
          "[Master] bus frame timeout set to #{target_ms}ms (slaves=#{slave_count}, dc_cycle_ns=#{inspect(data.dc_cycle_ns)})"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "[Master] failed to tune bus frame timeout to #{target_ms}ms: #{inspect(reason)}"
        )

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
      case data.dc_cycle_ns do
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
         {:ok, dc_ref_station} <- initialize_distributed_clocks(data, slave_topology),
         :ok <- start_domains(data),
         {:ok, effective_slave_config, slaves, pending_preop, activatable_slaves} <-
           start_slaves(data, count, if(dc_ref_station, do: data.dc_cycle_ns, else: nil)) do
      {:ok,
       %{
         data
         | dc_ref_station: dc_ref_station,
           slave_config: effective_slave_config,
           slaves: slaves,
           pending_preop: MapSet.new(pending_preop),
           activatable_slaves: activatable_slaves,
           activation_failures: %{},
           activation_phase: :preop_ready
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
               data.bus_pid,
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
      case Bus.transaction(data.bus_pid, Transaction.fprd(station, Registers.dl_status())) do
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

    with {:ok, [%{wkc: ^count}]} <-
           Bus.transaction(data.bus_pid, Transaction.bwr(Registers.al_control(0x11))),
         :ok <- verify_init_states(data, stations, @init_poll_limit) do
      :ok
    else
      {:ok, [%{wkc: wkc}]} ->
        {:error, {:init_reset_failed, {:unexpected_wkc, wkc, count}}}

      {:error, _} = err ->
        err
    end
  end

  defp verify_init_states(_data, _stations, 0), do: {:error, :init_verification_exhausted}

  defp verify_init_states(data, stations, attempts_left) do
    statuses = Enum.map(stations, &read_init_status(data, &1))

    if Enum.all?(statuses, &init_ready?/1) do
      :ok
    else
      if attempts_left == 1 do
        {:error, {:init_verification_failed, Enum.reject(statuses, &init_ready?/1)}}
      else
        Process.sleep(@init_poll_interval_ms)
        verify_init_states(data, stations, attempts_left - 1)
      end
    end
  end

  defp read_init_status(data, station) do
    case Bus.transaction(data.bus_pid, Transaction.fprd(station, Registers.al_status())) do
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
    case Bus.transaction(data.bus_pid, Transaction.fprd(station, Registers.al_status_code())) do
      {:ok, [%{data: <<code::16-little>>, wkc: 1}]} -> code
      _ -> nil
    end
  end

  defp init_ready?(%{state: 0x01, error: 0}), do: true
  defp init_ready?(_), do: false

  defp initialize_distributed_clocks(data, slave_topology) do
    case DC.initialize_clocks(data.bus_pid, slave_topology) do
      {:ok, ref_station} ->
        Logger.info("[Master] DC initialized, ref=0x#{Integer.to_string(ref_station, 16)}")
        {:ok, ref_station}

      {:error, reason} ->
        Logger.warning("[Master] DC init failed (#{inspect(reason)}) — running without DC")
        {:ok, nil}
    end
  end

  defp start_domains(data) do
    Enum.reduce_while(data.domain_config || [], :ok, fn entry, :ok ->
      domain_opts = normalize_domain_config(entry)
      id = Keyword.fetch!(domain_opts, :id)

      case DynamicSupervisor.start_child(
             EtherCAT.SessionSupervisor,
             {Domain, [{:id, id}, {:bus, data.bus_pid} | domain_opts]}
           ) do
        {:ok, _pid} ->
          {:cont, :ok}

        {:error, {:already_started, _pid}} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:domain_start_failed, id, reason}}}
      end
    end)
  end

  # Returns {:ok, effective_config, slaves_list, pending_preop_names, activatable_names}
  defp start_slaves(data, bus_count, dc_cycle_ns) do
    with {:ok, effective_config} <- effective_slave_config(data.slave_config || [], bus_count) do
      Enum.with_index(effective_config)
      |> Enum.reduce_while({:ok, [], [], []}, fn {entry, pos},
                                                 {:ok, slave_acc, pending_acc, activatable_acc} ->
        station = station_for_position(data, pos)
        slave_opts = normalize_slave_config(entry)
        name = Keyword.fetch!(slave_opts, :name)

        opts = [
          bus: data.bus_pid,
          station: station,
          name: name,
          driver: Keyword.get(slave_opts, :driver),
          config: Keyword.get(slave_opts, :config, %{}),
          process_data: Keyword.get(slave_opts, :process_data, :none),
          dc_cycle_ns: dc_cycle_ns
        ]

        case DynamicSupervisor.start_child(EtherCAT.SlaveSupervisor, {Slave, opts}) do
          {:ok, pid} ->
            next_activatable =
              if Keyword.get(slave_opts, :target_state, :op) == :op do
                [name | activatable_acc]
              else
                activatable_acc
              end

            {:cont,
             {:ok, [{name, station, pid} | slave_acc], [name | pending_acc], next_activatable}}

          {:error, reason} ->
            {:halt,
             {:error, {:slave_start_failed, name, station, reason}, Enum.reverse(slave_acc)}}
        end
      end)
      |> case do
        {:ok, slaves, pending, activatable} ->
          {:ok, effective_config, Enum.reverse(slaves), Enum.reverse(pending),
           Enum.reverse(activatable)}

        {:error, reason, started_slaves} ->
          {:error, reason, started_slaves}

        {:error, _} = err ->
          err
      end
    end
  end

  defp effective_slave_config([], bus_count), do: {:ok, dynamic_slave_configs(bus_count)}

  defp effective_slave_config(slave_config, bus_count) when length(slave_config) <= bus_count do
    {:ok, Enum.take(slave_config, bus_count)}
  end

  defp effective_slave_config(slave_config, bus_count) do
    {:error, {:configured_slaves_exceed_bus, length(slave_config), bus_count}}
  end

  defp get_domain_ids(domain_config) do
    Enum.map(domain_config, fn
      %EtherCAT.Domain.Config{id: id} -> id
      opts when is_list(opts) -> Keyword.fetch!(opts, :id)
    end)
  end

  # Runs synchronously in the scan/configuring handler before transitioning to :running.
  defp activate_network(%{activatable_slaves: []} = data) do
    Logger.info("[Master] dynamic startup: slaves held in :preop for runtime configuration")
    {:ok, %{data | activation_failures: %{}, activation_phase: :preop_ready}}
  end

  defp activate_network(data) do
    Logger.info("[Master] activating — starting DC, domains, and advancing slaves to :op")

    case start_dc_runtime(data) do
      {:ok, dc_pid} ->
        activation_data = %{data | dc_pid: dc_pid}

        case start_domain_cycles(activation_data) do
          :ok ->
            activation_failures = activate_required_slaves(activation_data.activatable_slaves)

            activated_data = %{activation_data | activation_failures: activation_failures}

            if map_size(activation_failures) == 0 do
              {:ok, %{activated_data | activation_phase: :operational}}
            else
              Logger.warning(
                "[Master] activation incomplete; degraded mode for #{inspect(Map.keys(activation_failures))}"
              )

              {:degraded, %{activated_data | activation_phase: :operational}}
            end

          {:error, reason} ->
            {:error, reason, activation_data}
        end

      {:error, reason} ->
        {:error, reason, data}
    end
  end

  # -- Session teardown ------------------------------------------------------

  defp stop_session(data) do
    if data.dc_pid do
      DynamicSupervisor.terminate_child(EtherCAT.SessionSupervisor, data.dc_pid)
    end

    Enum.each(data.slaves || [], fn entry ->
      pid = elem(entry, tuple_size(entry) - 1)
      DynamicSupervisor.terminate_child(EtherCAT.SlaveSupervisor, pid)
    end)

    Enum.each(get_domain_ids(data.domain_config || []), fn domain_id ->
      terminate_domain(domain_id)
    end)

    if data.bus_pid do
      DynamicSupervisor.terminate_child(EtherCAT.SessionSupervisor, data.bus_pid)
    end
  end

  defp start_dc_runtime(%{dc_ref_station: nil}), do: {:ok, nil}

  defp start_dc_runtime(data) do
    case DynamicSupervisor.start_child(
           EtherCAT.SessionSupervisor,
           {DC, bus: data.bus_pid, ref_station: data.dc_ref_station, period_ms: 10}
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, {:dc_start_failed, reason}}
    end
  end

  defp start_domain_cycles(data) do
    Enum.reduce_while(get_domain_ids(data.domain_config || []), :ok, fn id, :ok ->
      case Domain.start_cycling(id) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:domain_cycle_start_failed, id, reason}}}
      end
    end)
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

  defp retry_failed_activation(%{activation_failures: failures} = data) do
    retried_failures =
      Enum.reduce(failures, %{}, fn {name, _last_failure}, acc ->
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

    if map_size(retried_failures) == 0 do
      Logger.info("[Master] degraded recovery succeeded; all activatable slaves are in :op")
      {:ok, %{data | activation_failures: %{}}}
    else
      {:degraded, %{data | activation_failures: retried_failures}}
    end
  end

  defp phase_for(:idle, _data), do: :idle
  defp phase_for(:scanning, _data), do: :scanning
  defp phase_for(:configuring, _data), do: :configuring
  defp phase_for(:degraded, _data), do: :degraded
  defp phase_for(:running, %{activation_phase: :operational}), do: :operational
  defp phase_for(:running, _data), do: :preop_ready

  defp reply_await_callers(callers, reply) do
    Enum.each(callers, fn from -> :gen_statem.reply(from, reply) end)
  end

  defp terminate_domain(domain_id) do
    case Registry.lookup(EtherCAT.Registry, {:domain, domain_id}) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(EtherCAT.SessionSupervisor, pid)

      [] ->
        :ok
    end
  end
end
