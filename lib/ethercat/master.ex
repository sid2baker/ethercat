defmodule EtherCAT.Master do
  @moduledoc """
  EtherCAT master — singleton gen_statem registered as `EtherCAT.Master`.

  ## States

    - `:idle` — not started
    - `:scanning` — link open, discovering slaves
    - `:ready` — slaves started and in `:preop`

  ## Example

      EtherCAT.Master.start(
        interface: "eth0",
        slaves: [
          nil,                                                       # position 0 → 0x1000, no driver
          [name: :sensor, driver: MyApp.EL1809, config: %{}],       # position 1 → 0x1001
          [name: :valve,  driver: MyApp.EL2809, config: %{}]        # position 2 → 0x1002
        ]
      )

  Station addresses are assigned from list position: `base_station + index`.
  `nil` entries get a station address but no Slave gen_statem is started.

  ## Slave API (by name, not station)

      Slave.register_pdo(:sensor, :channels, :fast_domain)
      Slave.subscribe(:sensor, :channels, self())
      Slave.request(:sensor, :safeop)
      Slave.set_output(:valve, :outputs, 0xFFFF)
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.{DC, Domain, Link, Slave}
  alias EtherCAT.Link.Transaction
  alias EtherCAT.Slave.Registers

  @base_station 0x1000
  @confirm_rounds 3
  @scan_max_attempts 10
  @scan_retry_ms 200

  defstruct [
    :link_pid,
    :link_ref,
    :dc_pid,
    :slave_config,
    :domain_config,
    :dc_cycle_ns,
    base_station: @base_station,
    slaves: [],
    scan_attempts: 0
  ]

  # -- Public API ------------------------------------------------------------

  @doc """
  Start the master: open a link and scan for slaves.

  Options:
    - `:interface` (required) — e.g. `"eth0"`
    - `:slaves` — list of slave config entries, default `[]`. Each entry is either `nil` (station
      assigned, no driver) or a keyword list with keys: `:name`, `:driver`, `:config`, and
      `:pdos` (list of `{pdo_name, domain_id}` pairs to wire on `run/0`)
    - `:domains` — list of domain specs, default `[]`. Each entry is a keyword list with keys:
      `:id` (atom, required) and `:period` (ms, required), plus any `EtherCAT.Domain` options
    - `:base_station` — starting station address, default `0x1000`
    - `:dc_cycle_ns` — SYNC0 cycle time in ns for slaves with a `dc:` driver profile key (default `1_000_000` = 1 ms)
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: :gen_statem.call(__MODULE__, {:start, opts})

  @doc "Stop the master: shut down all slaves and close the link."
  @spec stop() :: :ok
  def stop, do: :gen_statem.call(__MODULE__, :stop)

  @doc "Return `[{name, station, pid}]` for all named slaves, or `[{station, pid}]` for anonymous."
  @spec slaves() :: list()
  def slaves, do: :gen_statem.call(__MODULE__, :slaves)

  @doc "Return the link pid."
  @spec link() :: pid() | nil
  def link, do: :gen_statem.call(__MODULE__, :link)

  @doc """
  Start all configured domains, wire PDOs, activate domains, then advance all
  slaves to `:op`. This is the single call that transitions the bus from
  `:preop` (after `start/1`) to fully operational.
  """
  @spec run() :: :ok | {:error, term()}
  def run, do: :gen_statem.call(__MODULE__, :run, 30_000)

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
           {Link, interface: interface, name: EtherCAT.Link}
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
            slaves: []
        }

        {:next_state, :scanning, %{new_data | dc_cycle_ns: dc_cycle_ns}, [{:reply, from, :ok}]}

      {:error, _} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def handle_event({:call, from}, {:start, _}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_started}}]}
  end

  def handle_event({:call, from}, _event, :idle, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_started}}]}
  end

  # :scanning ----------------------------------------------------------------

  def handle_event(:enter, _old, :scanning, _data) do
    {:keep_state_and_data, [{{:timeout, :scan}, 0, nil}]}
  end

  def handle_event({:timeout, :scan}, nil, :scanning, data) do
    attempt = data.scan_attempts + 1

    case do_scan(data) do
      {:ok, slaves, dc_pid} ->
        {:next_state, :ready, %{data | slaves: slaves, dc_pid: dc_pid, scan_attempts: 0}}

      {:error, reason} when attempt < @scan_max_attempts ->
        Logger.warning(
          "[Master] scan attempt #{attempt}/#{@scan_max_attempts} failed (#{inspect(reason)}) — retrying in #{@scan_retry_ms} ms"
        )

        {:keep_state, %{data | scan_attempts: attempt},
         [{{:timeout, :scan}, @scan_retry_ms, nil}]}

      {:error, reason} ->
        Logger.error("[Master] scan failed after #{attempt} attempts: #{inspect(reason)}")

        stop_session(data)
        {:next_state, :idle, %__MODULE__{}}
    end
  end

  def handle_event({:call, from}, :stop, :scanning, data) do
    stop_session(data)
    {:next_state, :idle, %__MODULE__{}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, _event, :scanning, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :scanning}}]}
  end

  # :ready -------------------------------------------------------------------

  def handle_event(:enter, _old, :ready, data) do
    Logger.info("[Master] ready — #{length(data.slaves)} slave(s) started")
    :keep_state_and_data
  end

  def handle_event({:call, from}, :stop, :ready, data) do
    stop_session(data)
    {:next_state, :idle, %__MODULE__{}, [{:reply, from, :ok}]}
  end

  # Link crashed — clean up and return to idle so caller can call start/1 again
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, _state, data)
      when ref == data.link_ref and not is_nil(ref) do
    Logger.error("[Master] Link crashed (#{inspect(reason)}) — returning to idle")
    stop_session(%{data | link_pid: nil})
    {:next_state, :idle, %__MODULE__{}}
  end

  # Stale :DOWN from a previous session (e.g. after scan failure cleanup) — ignore
  def handle_event(:info, {:DOWN, _ref, :process, _pid, _reason}, _state, _data) do
    :keep_state_and_data
  end

  def handle_event({:call, from}, :slaves, :ready, data) do
    {:keep_state_and_data, [{:reply, from, data.slaves}]}
  end

  def handle_event({:call, from}, :link, :ready, data) do
    {:keep_state_and_data, [{:reply, from, data.link_pid}]}
  end

  def handle_event({:call, from}, :run, :ready, data) do
    result = do_run(data)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def handle_event({:call, from}, _event, :ready, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_request}}]}
  end

  # -- Scan ------------------------------------------------------------------

  defp do_scan(data) do
    link = data.link_pid

    with {:ok, count} <- stable_count(link) do
      Logger.info("[Master] found #{count} slave(s) on bus")

      # Validate: if slave_config provided, warn if count doesn't match
      expected = Enum.count(data.slave_config || [], &(&1 != nil))

      if expected > 0 and count != length(data.slave_config || []) do
        Logger.warning(
          "[Master] bus has #{count} slaves but config lists #{length(data.slave_config || [])} positions"
        )
      end

      assign_stations(link, data.base_station, count)

      # Read DL status per station (needed for DC topology)
      slave_stations = read_dl_status_all(link, data.base_station, count)

      # DC initialization — non-fatal if no DC-capable slaves
      dc_pid =
        case DC.init(link, slave_stations) do
          {:ok, ref_station} ->
            Logger.info("[Master] DC initialized, ref=0x#{Integer.to_string(ref_station, 16)}")

            case DynamicSupervisor.start_child(
                   EtherCAT.SessionSupervisor,
                   {DC, link: link, ref_station: ref_station, period_ms: 10}
                 ) do
              {:ok, pid} ->
                pid

              {:error, reason} ->
                Logger.warning("[Master] DC gen_statem failed to start: #{inspect(reason)}")
                nil
            end

          {:error, reason} ->
            Logger.warning("[Master] DC init failed (#{inspect(reason)}) — running without DC")
            nil
        end

      with {:ok, slaves} <-
             start_slaves(link, data.base_station, count, data.slave_config || [],
               dc_pid: dc_pid,
               dc_cycle_ns: data.dc_cycle_ns
             ) do
        {:ok, slaves, dc_pid}
      end
    end
  end

  defp stable_count(link) do
    counts =
      for _ <- 1..@confirm_rounds do
        case Link.transaction(link, &Transaction.brd(&1, {0x0000, 1})) do
          {:ok, [%{wkc: n}]} -> n
          _ -> -1
        end
      end

    case Enum.uniq(counts) do
      [n] when n >= 0 -> {:ok, n}
      _ -> {:error, :unstable_slave_count}
    end
  end

  defp assign_stations(link, base, count) do
    Enum.each(0..(count - 1), fn pos ->
      station = base + pos
      Link.transaction(link, &Transaction.apwr(&1, pos, Registers.station_address(station)))
    end)
  end

  # Start slaves from the config list. Position in the list = station offset.
  # nil entries: station address is assigned but no Slave gen_statem is started.
  defp start_slaves(link, base, bus_count, slave_config, extra_opts) do
    dc_pid = Keyword.get(extra_opts, :dc_pid)
    dc_cycle_ns = Keyword.get(extra_opts, :dc_cycle_ns, 1_000_000)

    # Pad or trim config to match bus_count
    config_padded =
      slave_config
      |> Enum.take(bus_count)
      |> then(fn c -> c ++ List.duplicate(nil, max(0, bus_count - length(c))) end)

    slaves =
      config_padded
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, pos} ->
        station = base + pos

        case entry do
          nil ->
            # No driver for this position — station assigned, no gen_statem
            []

          slave_opts when is_list(slave_opts) ->
            name = Keyword.fetch!(slave_opts, :name)
            driver = Keyword.get(slave_opts, :driver)
            config = Keyword.get(slave_opts, :config, %{})

            # Pass dc_cycle_ns only when DC is running — slave uses it to configure SYNC0
            slave_dc_cycle_ns = if dc_pid != nil, do: dc_cycle_ns, else: nil

            opts = [
              link: link,
              station: station,
              name: name,
              driver: driver,
              config: config,
              dc_cycle_ns: slave_dc_cycle_ns
            ]

            case DynamicSupervisor.start_child(EtherCAT.SlaveSupervisor, {Slave, opts}) do
              {:ok, pid} ->
                [{name, station, pid}]

              {:error, reason} ->
                Logger.error(
                  "[Master] failed to start slave #{inspect(name)} at 0x#{Integer.to_string(station, 16)}: #{inspect(reason)}"
                )

                []
            end
        end
      end)

    {:ok, slaves}
  end

  defp read_dl_status_all(link, base, count) do
    Enum.map(0..(count - 1), fn pos ->
      station = base + pos

      case Link.transaction(link, &Transaction.fprd(&1, station, Registers.dl_status())) do
        {:ok, [%{data: status, wkc: 1}]} -> {station, status}
        _ -> {station, <<0, 0>>}
      end
    end)
  end

  # Start domains, wire PDOs, activate domains, advance all slaves to :op.
  defp do_run(data) do
    link = data.link_pid

    # 1. Start domain processes
    domain_ids =
      Enum.flat_map(data.domain_config || [], fn domain_opts ->
        id = Keyword.fetch!(domain_opts, :id)

        case DynamicSupervisor.start_child(
               EtherCAT.DomainSupervisor,
               {Domain, [{:id, id}, {:link, link} | domain_opts]}
             ) do
          {:ok, _pid} ->
            [id]

          {:error, {:already_started, _}} ->
            Logger.warning("[Master] domain #{inspect(id)} already started")
            [id]

          {:error, reason} ->
            Logger.error("[Master] failed to start domain #{inspect(id)}: #{inspect(reason)}")
            []
        end
      end)

    # 2. Register PDOs — walk slave config and wire each declared pdo → domain
    Enum.each(data.slave_config || [], fn entry ->
      with slave_opts when is_list(slave_opts) <- entry,
           name when not is_nil(name) <- Keyword.get(slave_opts, :name),
           pdos when pdos != [] <- Keyword.get(slave_opts, :pdos, []) do
        Enum.each(pdos, fn {pdo_name, domain_id} ->
          case Slave.register_pdo(name, pdo_name, domain_id) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[Master] register_pdo #{inspect(name)}.#{inspect(pdo_name)} → #{inspect(domain_id)} failed: #{inspect(reason)}"
              )
          end
        end)
      end
    end)

    # 3. Activate all domains — assigns FMMU logical offsets and starts cycling
    Enum.each(domain_ids, fn id ->
      case Domain.activate(id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[Master] domain #{inspect(id)} activate failed: #{inspect(reason)}")
      end
    end)

    # 4. Advance all named slaves to :op
    Enum.each(data.slaves, fn entry ->
      name = elem(entry, 0)

      case Slave.request(name, :op) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[Master] slave #{inspect(name)} → op failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # Terminate DC child (if any), all slave children, then Link.
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
end
