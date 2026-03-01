defmodule EtherCAT.Master do
  @moduledoc """
  EtherCAT master — singleton gen_statem registered as `EtherCAT.Master`.

  ## States

    - `:idle` — not started
    - `:scanning` — link open, polling bus for a stable slave count
    - `:configuring` — stations assigned, DC initialised, slaves spawned;
      waiting for all named slaves to reach `:preop`
    - `:running` — fully operational

  The state machine is fully self-driving. Call `start/1` once, then either
  poll `state/0` or block on `await_running/1`.

  ## Example

      EtherCAT.start(
        interface: "eth0",
        domains: [%EtherCAT.Domain.Config{id: :main, period: 1}],
        slaves: [
          nil,
          %EtherCAT.Slave.Config{name: :sensor, driver: MyApp.EL1809, domain: :main},
          %EtherCAT.Slave.Config{name: :valve,  driver: MyApp.EL2809, domain: :main}
        ]
      )
      :ok = EtherCAT.await_running()

  Station addresses are assigned from list position: `base_station + index`.
  `nil` entries get a station address but no Slave gen_statem is started.
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.{DC, Domain, Bus, Slave}
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Slave.Registers

  @base_station 0x1000

  # Scanning: poll every 100 ms, require 1 s of stable identical readings
  @scan_poll_ms 100
  @scan_stable_ms 1_000

  # Configuring: 30 s to receive :preop notifications from all slaves
  @configuring_timeout_ms 30_000

  defstruct [
    :link_pid,
    :link_ref,
    :dc_pid,
    # station address of the DC reference clock slave (nil if no DC)
    :dc_ref_station,
    :slave_config,
    :domain_config,
    :dc_cycle_ns,
    base_station: @base_station,
    slaves: [],
    # [{monotonic_ms, count}] — sliding window for scan stability
    scan_window: [],
    slave_count: nil,
    # MapSet of slave names still waiting to report :preop
    pending_preop: MapSet.new(),
    # blocked await_running callers — replied when :running is entered
    await_callers: []
  ]

  # -- Public API ------------------------------------------------------------

  @doc """
  Start the master: open a link and begin scanning for slaves.

  Options:
    - `:interface` (required) — e.g. `"eth0"`
    - `:slaves` — list of slave config entries, default `[]`. Each entry is either `nil`
      (station assigned, no driver) or a keyword list with keys: `:name`, `:driver`,
      `:config`, and `:pdos` (`[{pdo_name, domain_id}]` pairs — passed to the slave
      which self-registers in its `:preop` enter handler)
    - `:domains` — list of domain specs, default `[]`. Each entry is a keyword list with
      keys `:id` (atom, required) and `:period` (ms, required), plus any Domain options
    - `:base_station` — starting station address, default `0x1000`
    - `:dc_cycle_ns` — SYNC0 cycle time in ns for DC-capable slaves (default `1_000_000`)
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: :gen_statem.call(__MODULE__, {:start, opts})

  @doc "Stop the master: shut down all slaves, domains, and the link."
  @spec stop() :: :ok
  def stop, do: :gen_statem.call(__MODULE__, :stop)

  @doc "Return `[{name, station, pid}]` for all named slaves."
  @spec slaves() :: list()
  def slaves, do: :gen_statem.call(__MODULE__, :slaves)

  @doc "Return the link pid."
  @spec link() :: pid() | nil
  def link, do: :gen_statem.call(__MODULE__, :link)

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

    case DynamicSupervisor.start_child(
           EtherCAT.SessionSupervisor,
           {Bus, interface: interface, name: EtherCAT.Bus}
         ) do
      {:ok, link_pid} ->
        link_ref = Process.monitor(link_pid)

        new_data = %{
          data
          | link_pid: link_pid,
            link_ref: link_ref,
            base_station: base,
            slave_config: slave_config,
            domain_config: domain_config,
            dc_cycle_ns: dc_cycle_ns,
            slaves: [],
            scan_window: []
        }

        {:next_state, :scanning, new_data, [{:reply, from, :ok}]}

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
      case Bus.transaction_queue(data.link_pid, &Transaction.brd(&1, {0x0000, 1})) do
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
      Logger.info("[Master] bus stable — #{slave_count} slave(s)")
      configured = do_configure(%{data | scan_window: [], slave_count: slave_count})

      if MapSet.size(configured.pending_preop) == 0 do
        Logger.info("[Master] all slaves in :preop — activating")
        {:next_state, :running, do_activate(configured)}
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

      {:next_state, :running, do_activate(%{data | pending_preop: new_pending}),
       [{{:timeout, :configuring}, :cancel}]}
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

  # -- Shared handlers (all non-idle states) ---------------------------------

  # Query handlers — work in all active states
  def handle_event({:call, from}, :state, state, _data) do
    {:keep_state_and_data, [{:reply, from, state}]}
  end

  def handle_event({:call, from}, :slaves, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.slaves}]}
  end

  def handle_event({:call, from}, :link, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.link_pid}]}
  end

  # Catch-all for unrecognized calls in any active state
  def handle_event({:call, from}, _event, state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, state}}]}
  end

  # Link crashed — clean up and return to idle
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, _state, data)
      when ref == data.link_ref and not is_nil(ref) do
    Logger.error("[Master] Link crashed (#{inspect(reason)}) — returning to idle")
    reply_await_callers(data.await_callers, {:error, {:link_down, reason}})
    stop_session(%{data | link_pid: nil})
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

  defp assign_stations(link, base, count) do
    Enum.each(0..(count - 1), fn pos ->
      station = base + pos

      case Bus.transaction_queue(
             link,
             &Transaction.apwr(&1, pos, Registers.station_address(station))
           ) do
        {:ok, [%{wkc: 1}]} ->
          :ok

        {:ok, [%{wkc: wkc}]} ->
          Logger.warning("[Master] station assign pos=#{pos} wkc=#{wkc} (expected 1)")

        _ ->
          :ok
      end
    end)
  end

  defp read_dl_status_all(link, base, count) do
    Enum.map(0..(count - 1), fn pos ->
      station = base + pos

      case Bus.transaction_queue(link, &Transaction.fprd(&1, station, Registers.dl_status())) do
        {:ok, [%{data: status, wkc: 1}]} -> {station, status}
        _ -> {station, <<0, 0>>}
      end
    end)
  end

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
    [name: cfg.name, driver: cfg.driver, config: cfg.config, domain: cfg.domain, pdos: cfg.pdos]
  end

  defp normalize_slave_config(opts) when is_list(opts), do: opts

  defp start_domains(link, domain_config) do
    Enum.each(domain_config, fn entry ->
      domain_opts = normalize_domain_config(entry)
      id = Keyword.fetch!(domain_opts, :id)

      case DynamicSupervisor.start_child(
             EtherCAT.DomainSupervisor,
             {Domain, [{:id, id}, {:link, link} | domain_opts]}
           ) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _}} ->
          Logger.warning("[Master] domain #{inspect(id)} already started")

        {:error, reason} ->
          Logger.error("[Master] failed to start domain #{inspect(id)}: #{inspect(reason)}")
      end
    end)
  end

  # Returns {:ok, slaves_list, named_slave_names}
  # slaves_list: [{name, station, pid}] for named slaves
  # named_slave_names: [name] — names to track in pending_preop
  defp start_slaves(link, base, bus_count, slave_config, extra_opts) do
    dc_cycle_ns = Keyword.get(extra_opts, :dc_cycle_ns)

    # Pad or trim config to match bus_count
    config_padded =
      slave_config
      |> Enum.take(bus_count)
      |> then(fn c -> c ++ List.duplicate(nil, max(0, bus_count - length(c))) end)

    {slaves, named_names} =
      config_padded
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {entry, pos}, {slave_acc, names_acc} ->
        station = base + pos

        case entry do
          nil ->
            {slave_acc, names_acc}

          entry when is_list(entry) or is_struct(entry, EtherCAT.Slave.Config) ->
            slave_opts = normalize_slave_config(entry)
            name = Keyword.fetch!(slave_opts, :name)
            driver = Keyword.get(slave_opts, :driver)
            config = Keyword.get(slave_opts, :config, %{})
            pdos = Keyword.get(slave_opts, :pdos, [])
            domain = Keyword.get(slave_opts, :domain)

            opts = [
              link: link,
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
                {[{name, station, pid} | slave_acc], [name | names_acc]}

              {:error, reason} ->
                Logger.error(
                  "[Master] failed to start slave #{inspect(name)} at 0x#{Integer.to_string(station, 16)}: #{inspect(reason)}"
                )

                {slave_acc, names_acc}
            end
        end
      end)

    {:ok, Enum.reverse(slaves), named_names}
  end

  defp get_domain_ids(domain_config) do
    Enum.map(domain_config, fn
      %EtherCAT.Domain.Config{id: id} -> id
      opts when is_list(opts) -> Keyword.fetch!(opts, :id)
    end)
  end

  # Runs synchronously in the scan handler before transitioning to :configuring/:running.
  defp do_configure(data) do
    link = data.link_pid
    count = data.slave_count

    Logger.info("[Master] configuring #{count} slave(s)")

    assign_stations(link, data.base_station, count)
    slave_stations = read_dl_status_all(link, data.base_station, count)

    # DC hardware init (delays, offsets, PLL filter reset) before INIT→PREOP.
    # The DC gen_statem (cyclic ARMW) is started later in do_activate, after
    # all slaves reach PREOP, so its ticks don't compete with slave init.
    dc_ref_station =
      case DC.init(link, slave_stations) do
        {:ok, ref_station} ->
          Logger.info("[Master] DC initialized, ref=0x#{Integer.to_string(ref_station, 16)}")
          ref_station

        {:error, reason} ->
          Logger.warning("[Master] DC init failed (#{inspect(reason)}) — running without DC")
          nil
      end

    # Start domains before slaves so domains are registered in the Registry
    # when slaves call Domain.register_pdo/4 in their :preop enter.
    start_domains(link, data.domain_config || [])

    {:ok, slaves, named_slaves} =
      start_slaves(link, data.base_station, count, data.slave_config || [],
        dc_cycle_ns: if(dc_ref_station, do: data.dc_cycle_ns, else: nil)
      )

    %{
      data
      | dc_ref_station: dc_ref_station,
        slaves: slaves,
        pending_preop: MapSet.new(named_slaves)
    }
  end

  # Runs synchronously in the scan/configuring handler before transitioning to :running.
  defp do_activate(data) do
    Logger.info("[Master] activating — starting DC, domains, and advancing slaves to :op")

    # Start DC cyclic ARMW now — all slaves are in PREOP so the socket is clean
    # and DC ticks won't compete with slave state transitions.
    dc_pid =
      if data.dc_ref_station do
        case DynamicSupervisor.start_child(
               EtherCAT.SessionSupervisor,
               {DC, link: data.link_pid, ref_station: data.dc_ref_station, period_ms: 10}
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

    Enum.each(data.slaves, fn {name, _station, _pid} ->
      case Slave.request(name, :safeop) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[Master] slave #{inspect(name)} → safeop failed: #{inspect(reason)}")
      end
    end)

    Enum.each(data.slaves, fn {name, _station, _pid} ->
      case Slave.request(name, :op) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[Master] slave #{inspect(name)} → op failed: #{inspect(reason)}")
      end
    end)

    %{data | dc_pid: dc_pid}
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

    if data.link_pid do
      DynamicSupervisor.terminate_child(EtherCAT.SessionSupervisor, data.link_pid)
    end
  end

  defp reply_await_callers(callers, reply) do
    Enum.each(callers, fn from -> :gen_statem.reply(from, reply) end)
  end
end
