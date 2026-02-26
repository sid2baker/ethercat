defmodule EtherCAT.Master do
  @moduledoc """
  EtherCAT master — singleton gen_statem registered as `EtherCAT.Master`.

  Manages the link layer and slave discovery. Slaves are started under
  `EtherCAT.SlaveSupervisor` and auto-advance to `:preop` on their own.

  ## States

    - `:idle` — not started, no link open
    - `:scanning` — link open, discovering and assigning station addresses
    - `:ready` — slaves started and advancing to preop

  ## Example

      EtherCAT.Master.start(interface: "enp0s31f6")
      EtherCAT.Master.slaves()
      #=> [{0x1000, #PID<...>}, {0x1001, #PID<...>}]

      EtherCAT.Master.go_operational()
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.{Link, Slave}
  alias EtherCAT.Link.Transaction
  alias EtherCAT.Slave.ProcessImage

  @base_station 0x1000
  @station_reg 0x0010
  @confirm_rounds 3

  defstruct [:link, :layout, base_station: @base_station, slaves: []]

  # -- Public API ------------------------------------------------------------

  @doc """
  Start the master: open a link to `interface` and scan for slaves.

  Options:
    - `:interface` (required) — e.g. `"eth0"`
    - `:base_station` — starting station address (default `0x1000`)
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: :gen_statem.call(__MODULE__, {:start, opts})

  @doc "Stop the master: shut down all slaves and close the link."
  @spec stop() :: :ok
  def stop, do: :gen_statem.call(__MODULE__, :stop)

  @doc "Return `[{station, pid}]` for all discovered slaves."
  @spec slaves() :: [{non_neg_integer(), pid()}]
  def slaves, do: :gen_statem.call(__MODULE__, :slaves)

  @doc "Return the pid for a single slave by station address, or nil."
  @spec slave(non_neg_integer()) :: pid() | nil
  def slave(station), do: :gen_statem.call(__MODULE__, {:slave, station})

  @doc "Return the link pid."
  @spec link() :: pid() | nil
  def link, do: :gen_statem.call(__MODULE__, :link)

  @doc "Request all slaves to transition to `:op`. Logs but does not abort on individual failures."
  @spec go_operational() :: :ok
  def go_operational, do: :gen_statem.call(__MODULE__, :go_operational)

  @doc "Configure SM and FMMU registers for all slaves. Call once after `go_operational/0`."
  @spec configure() :: :ok | {:error, term()}
  def configure, do: :gen_statem.call(__MODULE__, :configure)

  @doc """
  Run one cyclic process image exchange.

  `outputs` is `%{station => binary()}`. Returns `{:ok, %{station => binary()}}`.
  """
  @spec cycle(%{non_neg_integer() => binary()}) ::
          {:ok, %{non_neg_integer() => binary()}} | {:error, term()}
  def cycle(outputs), do: :gen_statem.call(__MODULE__, {:cycle, outputs})

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

    case Link.start_link(interface: interface) do
      {:ok, link} ->
        {:next_state, :scanning, %{data | link: link, base_station: base, slaves: []},
         [{:reply, from, :ok}]}

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
    Logger.info("[Master] ready — #{length(data.slaves)} slave(s) discovered")
    :keep_state_and_data
  end

  def handle_event({:call, from}, :stop, :ready, data) do
    Enum.each(data.slaves, fn {_s, pid} ->
      DynamicSupervisor.terminate_child(EtherCAT.SlaveSupervisor, pid)
    end)

    :gen_statem.stop(data.link)
    {:next_state, :idle, %__MODULE__{}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :slaves, :ready, data) do
    {:keep_state_and_data, [{:reply, from, data.slaves}]}
  end

  def handle_event({:call, from}, {:slave, station}, :ready, data) do
    pid =
      case List.keyfind(data.slaves, station, 0) do
        {^station, pid} -> pid
        nil -> nil
      end

    {:keep_state_and_data, [{:reply, from, pid}]}
  end

  def handle_event({:call, from}, :link, :ready, data) do
    {:keep_state_and_data, [{:reply, from, data.link}]}
  end

  def handle_event({:call, from}, :go_operational, :ready, data) do
    Enum.each(data.slaves, fn {station, _pid} ->
      case Slave.request(station, :op) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Master] slave 0x#{Integer.to_string(station, 16)} -> op failed: #{inspect(reason)}"
          )
      end
    end)

    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :configure, :ready, data) do
    case ProcessImage.configure(data.link, data.slaves, load_profiles()) do
      {:ok, layout} ->
        {:keep_state, %{data | layout: layout}, [{:reply, from, :ok}]}

      {:error, _} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def handle_event({:call, from}, {:cycle, _outputs}, :ready, %{layout: nil} = _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_configured}}]}
  end

  def handle_event({:call, from}, {:cycle, outputs}, :ready, data) do
    reply = ProcessImage.cycle(data.link, data.layout, outputs)
    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  def handle_event({:call, from}, _event, :ready, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_request}}]}
  end

  # -- Scan ------------------------------------------------------------------

  defp load_profiles, do: Application.get_env(:ethercat, :io_profiles, %{})

  defp do_scan(data) do
    with {:ok, count} <- stable_count(data.link) do
      Logger.info("[Master] found #{count} slave(s)")
      assign_stations(data.link, data.base_station, count)
      start_slaves(data.link, data.base_station, count)
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

  defp start_slaves(link, base, count) do
    slaves =
      for pos <- 0..(count - 1) do
        station = base + pos

        case DynamicSupervisor.start_child(
               EtherCAT.SlaveSupervisor,
               {Slave, link: link, station: station}
             ) do
          {:ok, pid} ->
            {station, pid}

          {:error, reason} ->
            Logger.error(
              "[Master] failed to start slave 0x#{Integer.to_string(station, 16)}: #{inspect(reason)}"
            )

            nil
        end
      end

    {:ok, Enum.reject(slaves, &is_nil/1)}
  end
end
