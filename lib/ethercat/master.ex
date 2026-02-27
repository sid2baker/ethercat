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

  alias EtherCAT.{Link, Slave}
  alias EtherCAT.Link.Transaction

  @base_station 0x1000
  @station_reg 0x0010
  @confirm_rounds 3

  defstruct [:link, :slave_config, base_station: @base_station, slaves: []]

  # -- Public API ------------------------------------------------------------

  @doc """
  Start the master: open a link and scan for slaves.

  Options:
    - `:interface` (required) — e.g. `"eth0"`
    - `:slaves` — list of slave config entries (see module doc), default `[]`
    - `:base_station` — starting station address, default `0x1000`
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

  @doc "Request all named slaves to transition to `:op`."
  @spec go_operational() :: :ok
  def go_operational, do: :gen_statem.call(__MODULE__, :go_operational)

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

    case Link.start_link(interface: interface) do
      {:ok, link} ->
        new_data = %{
          data
          | link: link,
            base_station: base,
            slave_config: slave_config,
            slaves: []
        }

        {:next_state, :scanning, new_data, [{:reply, from, :ok}]}

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
    case do_scan(data) do
      {:ok, slaves} ->
        {:next_state, :ready, %{data | slaves: slaves}}

      {:error, reason} ->
        Logger.error("[Master] scan failed: #{inspect(reason)}")
        :gen_statem.stop(data.link)
        {:next_state, :idle, %__MODULE__{}}
    end
  end

  def handle_event({:call, from}, :stop, :scanning, data) do
    :gen_statem.stop(data.link)
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
    Enum.each(data.slaves, fn entry ->
      pid = elem(entry, tuple_size(entry) - 1)
      DynamicSupervisor.terminate_child(EtherCAT.SlaveSupervisor, pid)
    end)

    :gen_statem.stop(data.link)
    {:next_state, :idle, %__MODULE__{}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :slaves, :ready, data) do
    {:keep_state_and_data, [{:reply, from, data.slaves}]}
  end

  def handle_event({:call, from}, :link, :ready, data) do
    {:keep_state_and_data, [{:reply, from, data.link}]}
  end

  def handle_event({:call, from}, :go_operational, :ready, data) do
    Enum.each(data.slaves, fn entry ->
      name = elem(entry, 0)

      case Slave.request(name, :op) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[Master] slave #{inspect(name)} → op failed: #{inspect(reason)}")
      end
    end)

    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, _event, :ready, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_request}}]}
  end

  # -- Scan ------------------------------------------------------------------

  defp do_scan(data) do
    with {:ok, count} <- stable_count(data.link) do
      Logger.info("[Master] found #{count} slave(s) on bus")

      # Validate: if slave_config provided, warn if count doesn't match non-nil entries
      expected = Enum.count(data.slave_config || [], &(&1 != nil))

      if expected > 0 and count != length(data.slave_config || []) do
        Logger.warning(
          "[Master] bus has #{count} slaves but config lists #{length(data.slave_config || [])} positions"
        )
      end

      assign_stations(data.link, data.base_station, count)
      start_slaves(data.link, data.base_station, count, data.slave_config || [])
    end
  end

  defp stable_count(link) do
    counts =
      for _ <- 1..@confirm_rounds do
        case Link.transaction(link, &Transaction.brd(&1, 0x0000, 1)) do
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
      Link.transaction(link, &Transaction.apwr(&1, pos, @station_reg, <<station::16-little>>))
    end)
  end

  # Start slaves from the config list. Position in the list = station offset.
  # nil entries: station address is assigned but no Slave gen_statem is started.
  defp start_slaves(link, base, bus_count, slave_config) do
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

            opts = [
              link: link,
              station: station,
              name: name,
              driver: driver,
              config: config
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
end
