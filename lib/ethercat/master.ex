defmodule EtherCAT.Master do
  @moduledoc """
  EtherCAT master — singleton gen_statem registered as `EtherCAT.Master`.

  ## States

    - `:idle` — not started
    - `:scanning` — bus open, polling for a stable slave count
    - `:configuring` — stations assigned, DC initialised, slaves spawned;
      waiting for all named slaves to reach `:preop`
    - `:running` — fully operational
    - `:degraded` — startup completed partially; failed slave promotions are retried

  The state machine is fully self-driving. Call `start/1` once, then either
  poll `state/0` or block on `await_running/1`.

  ## Example

      EtherCAT.start(
        interface: "eth0",
        domains: [%EtherCAT.Domain.Config{id: :main, period: 1}],
        slaves: [
          %EtherCAT.Slave.Config{name: :coupler},
          %EtherCAT.Slave.Config{name: :sensor, driver: MyApp.EL1809, domain: :main},
          %EtherCAT.Slave.Config{name: :valve,  driver: MyApp.EL2809, domain: :main}
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
    await_callers: []
  ]

  # -- Public API ------------------------------------------------------------

  @doc """
  Start the master: open a bus and begin scanning for slaves.

  Options:
    - `:interface` (required) — e.g. `"eth0"`
    - `:slaves` — list of slave config entries, default `[]`. Each entry is a
      `%EtherCAT.Slave.Config{}` (or equivalent keyword list) with keys: `:name`, `:driver`,
      `:config`, and `:pdos` (`[{pdo_name, domain_id}]` pairs — passed to the slave
      which self-registers in its `:preop` enter handler). `nil` entries are rejected.
      If omitted, dynamic default slaves are started for all discovered stations and
      held in `:preop` for runtime configuration.
    - `:domains` — list of domain specs, default `[]`. Each entry is a keyword list with
      keys `:id` (atom, required) and `:period` (ms, required), plus any Domain options
    - `:base_station` — starting station address, default `0x1000`
    - `:dc_cycle_ns` — SYNC0 cycle time in ns for DC-capable slaves (default `1_000_000`)
    - `:frame_timeout_ms` — optional fixed bus frame response timeout (ms); if omitted,
      master auto-tunes from slave count + cycle time
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
  Block until the master reaches `:running`, then return `:ok`.

  Returns immediately if already `:running`. Returns `{:error, :timeout}` if
  the master does not reach `:running` within `timeout_ms` milliseconds.
  Returns `{:error, :not_started}` if the master is `:idle`.
  """
  @spec await_running(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_running(timeout_ms \\ 10_000) do
    :gen_statem.call(__MODULE__, :await_running, timeout_ms)
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
    interface = Keyword.fetch!(opts, :interface)
    base = Keyword.get(opts, :base_station, @base_station)
    slave_config = Keyword.get(opts, :slaves, [])
    domain_config = Keyword.get(opts, :domains, [])
    dc_cycle_ns = Keyword.get(opts, :dc_cycle_ns, 1_000_000)
    frame_timeout_override_ms = Keyword.get(opts, :frame_timeout_ms)

    with :ok <- validate_slave_start_config(slave_config) do
      bus_opts =
        [interface: interface, name: EtherCAT.Bus]
        |> maybe_put_frame_timeout(frame_timeout_override_ms)

      case DynamicSupervisor.start_child(
             EtherCAT.SessionSupervisor,
             {Bus, bus_opts}
           ) do
        {:ok, bus_pid} ->
          bus_ref = Process.monitor(bus_pid)

          new_data = %{
            data
            | bus_pid: bus_pid,
              bus_ref: bus_ref,
              base_station: base,
              slave_config: slave_config,
              domain_config: domain_config,
              dc_cycle_ns: dc_cycle_ns,
              frame_timeout_override_ms: frame_timeout_override_ms,
              activatable_slaves: [],
              slaves: [],
              scan_window: [],
              activation_failures: %{}
          }

          {:next_state, :scanning, new_data, [{:reply, from, :ok}]}

        {:error, _} = err ->
          {:keep_state_and_data, [{:reply, from, err}]}
      end
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

  def handle_event({:call, from}, :await_running, :idle, _data) do
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
      case Bus.transaction(data.bus_pid, Transaction.brd({0x0000, 1})) do
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
      configured = do_configure(%{data | scan_window: [], slave_count: slave_count})

      if MapSet.size(configured.pending_preop) == 0 do
        Logger.info("[Master] all slaves in :preop — activating")

        case do_activate(configured) do
          {:ok, active_data} -> {:next_state, :running, active_data}
          {:degraded, degraded_data} -> {:next_state, :degraded, degraded_data}
        end
      else
        {:next_state, :configuring, configured}
      end
    else
      {:keep_state, %{data | scan_window: new_window},
       [{{:timeout, :scan_poll}, @scan_poll_ms, nil}]}
    end
  end

  def handle_event({:call, from}, :stop, :scanning, data) do
    stop_session(data)
    {:next_state, :idle, %__MODULE__{}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, :scanning, data) do
    {:keep_state, %{data | await_callers: [from | data.await_callers]}}
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

      case do_activate(%{data | pending_preop: new_pending}) do
        {:ok, active_data} ->
          {:next_state, :running, active_data, [{{:timeout, :configuring}, :cancel}]}

        {:degraded, degraded_data} ->
          {:next_state, :degraded, degraded_data, [{{:timeout, :configuring}, :cancel}]}
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
    {:next_state, :idle, %__MODULE__{}}
  end

  def handle_event({:call, from}, :stop, :configuring, data) do
    stop_session(data)
    reply_await_callers(data.await_callers, {:error, :stopped})
    {:next_state, :idle, %__MODULE__{}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, :configuring, data) do
    {:keep_state, %{data | await_callers: [from | data.await_callers]}}
  end

  # :running -----------------------------------------------------------------

  def handle_event(:enter, _old, :running, data) do
    Logger.info("[Master] running")
    reply_await_callers(data.await_callers, :ok)
    {:keep_state, %{data | await_callers: []}}
  end

  def handle_event({:call, from}, :stop, :running, data) do
    stop_session(data)
    {:next_state, :idle, %__MODULE__{}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, :running, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  # :degraded ----------------------------------------------------------------

  def handle_event(:enter, _old, :degraded, data) do
    Logger.warning("[Master] degraded startup; retrying failed slave promotions")

    reply_await_callers(
      data.await_callers,
      {:error, {:activation_failed, data.activation_failures}}
    )

    {:keep_state, %{data | await_callers: []},
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
    {:next_state, :idle, %__MODULE__{}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :await_running, :degraded, data) do
    {:keep_state_and_data,
     [{:reply, from, {:error, {:activation_failed, data.activation_failures}}}]}
  end

  # -- Shared handlers (all non-idle states) ---------------------------------

  # Query handlers — work in all active states
  def handle_event({:call, from}, :state, state, _data) do
    {:keep_state_and_data, [{:reply, from, state}]}
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

  # -- Bus setup helpers -----------------------------------------------------

  defp assign_stations(bus, base, count) do
    Enum.each(0..(count - 1), fn pos ->
      station = base + pos

      case Bus.transaction(bus, Transaction.apwr(pos, Registers.station_address(station))) do
        {:ok, [%{wkc: 1}]} ->
          :ok

        {:ok, [%{wkc: wkc}]} ->
          Logger.warning("[Master] station assign pos=#{pos} wkc=#{wkc} (expected 1)")

        _ ->
          :ok
      end
    end)
  end

  defp read_dl_status_all(bus, base, count) do
    Enum.map(0..(count - 1), fn pos ->
      station = base + pos

      case Bus.transaction(bus, Transaction.fprd(station, Registers.dl_status())) do
        {:ok, [%{data: status, wkc: 1}]} -> {station, status}
        _ -> {station, <<0, 0>>}
      end
    end)
  end

  defp validate_slave_start_config(slave_config) when is_list(slave_config) do
    case Enum.find_index(slave_config, &is_nil/1) do
      nil ->
        :ok

      idx ->
        {:error, {:invalid_slave_config, {:nil_entry, idx}}}
    end
  end

  defp validate_slave_start_config(_), do: {:error, {:invalid_slave_config, :invalid_list}}

  defp normalize_domain_config(%EtherCAT.Domain.Config{} = cfg) do
    [
      id: cfg.id,
      period: cfg.period,
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
      domain: cfg.domain,
      pdos: cfg.pdos,
      auto_activate?: true
    ]
  end

  defp normalize_slave_config(opts) when is_list(opts) do
    [
      name: Keyword.fetch!(opts, :name),
      driver: normalize_slave_driver(Keyword.get(opts, :driver)),
      config: Keyword.get(opts, :config, %{}),
      domain: Keyword.get(opts, :domain),
      pdos: Keyword.get(opts, :pdos, []),
      auto_activate?: Keyword.get(opts, :auto_activate?, true)
    ]
  end

  defp normalize_slave_driver(nil), do: DefaultSlaveDriver
  defp normalize_slave_driver(driver), do: driver

  defp dynamic_slave_configs(0), do: []

  defp dynamic_slave_configs(bus_count) do
    Enum.map(0..(bus_count - 1), fn pos ->
      [
        name: dynamic_slave_name(pos),
        driver: DefaultSlaveDriver,
        config: %{},
        domain: nil,
        pdos: [],
        auto_activate?: false
      ]
    end)
  end

  defp dynamic_slave_name(0), do: :coupler
  defp dynamic_slave_name(pos), do: :"slave_#{pos}"

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

  defp start_domains(bus, domain_config) do
    Enum.each(domain_config, fn entry ->
      domain_opts = normalize_domain_config(entry)
      id = Keyword.fetch!(domain_opts, :id)

      case DynamicSupervisor.start_child(
             EtherCAT.SessionSupervisor,
             {Domain, [{:id, id}, {:bus, bus} | domain_opts]}
           ) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          Logger.warning("[Master] domain #{inspect(id)} already started")
          :ok

        {:error, reason} ->
          Logger.error("[Master] failed to start domain #{inspect(id)}: #{inspect(reason)}")
          :ok
      end
    end)
  end

  # Returns {:ok, slaves_list, pending_preop_names, activatable_names}
  # slaves_list: [{name, station, pid}] for named slaves
  # pending_preop_names: [name] — names to track in pending_preop
  # activatable_names: [name] — names the master should move PREOP→OP
  defp start_slaves(bus, base, bus_count, slave_config, extra_opts) do
    dc_cycle_ns = Keyword.get(extra_opts, :dc_cycle_ns)
    effective_config = if(slave_config == [], do: dynamic_slave_configs(bus_count), else: [])

    {slaves, pending_names, activatable_names} =
      effective_config
      |> Kernel.++(Enum.take(slave_config, bus_count))
      |> Enum.with_index()
      |> Enum.reduce({[], [], []}, fn {entry, pos}, {slave_acc, pending_acc, activatable_acc} ->
        station = base + pos

        case entry do
          entry when is_list(entry) or is_struct(entry, EtherCAT.Slave.Config) ->
            slave_opts = normalize_slave_config(entry)
            name = Keyword.fetch!(slave_opts, :name)
            driver = Keyword.get(slave_opts, :driver)
            config = Keyword.get(slave_opts, :config, %{})
            pdos = Keyword.get(slave_opts, :pdos, [])
            domain = Keyword.get(slave_opts, :domain)
            auto_activate? = Keyword.get(slave_opts, :auto_activate?, true)

            opts = [
              bus: bus,
              station: station,
              name: name,
              driver: driver,
              config: config,
              pdos: pdos,
              domain: domain,
              dc_cycle_ns: dc_cycle_ns
            ]

            case DynamicSupervisor.start_child(EtherCAT.SlaveSupervisor, {Slave, opts}) do
              {:ok, pid} ->
                activatable_acc =
                  if auto_activate? do
                    [name | activatable_acc]
                  else
                    activatable_acc
                  end

                {[{name, station, pid} | slave_acc], [name | pending_acc], activatable_acc}

              {:error, reason} ->
                Logger.error(
                  "[Master] failed to start slave #{inspect(name)} at 0x#{Integer.to_string(station, 16)}: #{inspect(reason)}"
                )

                {slave_acc, pending_acc, activatable_acc}
            end

          invalid_entry ->
            Logger.warning(
              "[Master] invalid slave config at position #{pos}: #{inspect(invalid_entry)}"
            )

            {slave_acc, pending_acc, activatable_acc}
        end
      end)

    {:ok, Enum.reverse(slaves), Enum.reverse(pending_names), Enum.reverse(activatable_names)}
  end

  defp get_domain_ids(domain_config) do
    Enum.map(domain_config, fn
      %EtherCAT.Domain.Config{id: id} -> id
      opts when is_list(opts) -> Keyword.fetch!(opts, :id)
    end)
  end

  # Runs synchronously in the scan handler before transitioning to :configuring/:running.
  defp do_configure(data) do
    bus = data.bus_pid
    count = data.slave_count

    Logger.info("[Master] configuring #{count} slave(s)")

    assign_stations(bus, data.base_station, count)
    slave_stations = read_dl_status_all(bus, data.base_station, count)

    # DC hardware init (delays, offsets, PLL filter reset) before INIT→PREOP.
    # The DC gen_statem (cyclic ARMW) is started later in do_activate, after
    # all slaves reach PREOP, so its ticks don't compete with slave init.
    dc_ref_station =
      case DC.initialize_clocks(bus, slave_stations) do
        {:ok, ref_station} ->
          Logger.info("[Master] DC initialized, ref=0x#{Integer.to_string(ref_station, 16)}")
          ref_station

        {:error, reason} ->
          Logger.warning("[Master] DC init failed (#{inspect(reason)}) — running without DC")
          nil
      end

    # Start domains before slaves so domains are registered in the Registry
    # when slaves call Domain.register_pdo/4 in their :preop enter.
    start_domains(bus, data.domain_config || [])

    {:ok, slaves, pending_preop, activatable_slaves} =
      start_slaves(bus, data.base_station, count, data.slave_config || [],
        dc_cycle_ns: if(dc_ref_station, do: data.dc_cycle_ns, else: nil)
      )

    %{
      data
      | dc_ref_station: dc_ref_station,
        slaves: slaves,
        pending_preop: MapSet.new(pending_preop),
        activatable_slaves: activatable_slaves,
        activation_failures: %{}
    }
  end

  # Runs synchronously in the scan/configuring handler before transitioning to :running.
  defp do_activate(%{activatable_slaves: []} = data) do
    Logger.info("[Master] dynamic startup: slaves held in :preop for runtime configuration")
    {:ok, %{data | activation_failures: %{}}}
  end

  defp do_activate(data) do
    Logger.info("[Master] activating — starting DC, domains, and advancing slaves to :op")

    # Start DC cyclic ARMW now — all slaves are in PREOP so the socket is clean
    # and DC ticks won't compete with slave state transitions.
    dc_pid =
      if data.dc_ref_station do
        case DynamicSupervisor.start_child(
               EtherCAT.SessionSupervisor,
               {DC, bus: data.bus_pid, ref_station: data.dc_ref_station, period_ms: 10}
             ) do
          {:ok, pid} ->
            pid

          {:error, reason} ->
            Logger.warning("[Master] DC gen_statem failed to start: #{inspect(reason)}")
            nil
        end
      end

    domain_ids = get_domain_ids(data.domain_config || [])

    Enum.each(domain_ids, fn id ->
      case Domain.start_cycling(id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Master] domain #{inspect(id)} start_cycling failed: #{inspect(reason)}"
          )
      end
    end)

    activation_failures = activate_required_slaves(data.activatable_slaves)
    activated_data = %{data | dc_pid: dc_pid, activation_failures: activation_failures}

    if map_size(activation_failures) == 0 do
      {:ok, activated_data}
    else
      Logger.warning(
        "[Master] activation incomplete; degraded mode for #{inspect(Map.keys(activation_failures))}"
      )

      {:degraded, activated_data}
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
