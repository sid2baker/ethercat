defmodule EtherCAT do
  @moduledoc """
  Driver-backed runtime API for EtherCAT.

  Normal applications should interact with EtherCAT through:

  - `start/1`
  - `stop/0`
  - `state/0`
  - `await_running/1`
  - `await_operational/1`
  - `slaves/0`
  - `snapshot/0`
  - `snapshot/1`
  - `describe/1`
  - `inventory/0`
  - `subscribe/2`
  - `command/3`

  Specialist APIs live under:

  - `EtherCAT.Provisioning` for PREOP configuration, activation, and SDO traffic
  - `EtherCAT.Diagnostics` for DC, slave, domain, and topology inspection
  - `EtherCAT.Raw` for direct PDO reads, writes, and raw signal subscriptions
  - `EtherCAT.Driver` for driver authors
  - `EtherCAT.Simulator` for testing and simulator workflows

  `snapshot/0` is a best-effort aggregate view. It assembles the latest retained
  slave snapshots across slave runtimes at query time. The root `:cycle` is
  the latest observed domain cycle count across active domains when the
  snapshot is built; it is not a global atomic transaction boundary across all
  slaves.

  Drivers describe native endpoints. Slave configs may alias those endpoint
  names per slave. Public snapshots, descriptions, and `:signal_changed`
  events use the effective alias-applied endpoint names.
  """

  alias EtherCAT.Domain
  alias EtherCAT.Event
  alias EtherCAT.Master
  alias EtherCAT.SlaveDescription
  alias EtherCAT.SlaveSnapshot
  alias EtherCAT.Snapshot
  alias EtherCAT.Slave

  @typedoc """
  Public master session states returned by `state/0` once the local query
  succeeds.
  """
  @type session_state ::
          :idle
          | :discovering
          | :awaiting_preop
          | :preop_ready
          | :deactivated
          | :operational
          | :activation_blocked
          | :recovering

  @typedoc """
  Local wrapper errors returned when a synchronous master query cannot complete.
  """
  @type master_query_error :: {:error, :not_started | :timeout | {:server_exit, term()}}

  @typedoc """
  Successful query value wrapped with `:ok`, or a local master query error.
  """
  @type master_query_result(value) :: {:ok, value} | master_query_error()

  @typedoc "Configured runtime slave name."
  @type slave_name :: atom()

  @typedoc "Effective public slave description for one configured slave."
  @type description :: SlaveDescription.t()

  @typedoc "Effective descriptions for all configured slaves keyed by slave name."
  @type inventory :: %{optional(slave_name()) => description()}

  @typedoc "Driver-backed aggregate snapshot for the current session."
  @type snapshot :: Snapshot.t()

  @typedoc "Driver-backed snapshot for one named slave."
  @type slave_snapshot :: SlaveSnapshot.t()

  @typedoc "Public slave event emitted by `subscribe/2`."
  @type event :: Event.t()

  @doc """
  Start the master: open the interface, discover slaves, and begin
  self-driving configuration.
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: Master.start(opts)

  @doc """
  Stop the master: tear the session down completely.

  Returns `{:error, :already_stopped}` if not running.
  """
  @spec stop() :: :ok | {:error, :already_stopped | :timeout | {:server_exit, term()}}
  def stop do
    case Master.stop() do
      :ok -> :ok
      :already_stopped -> {:error, :already_stopped}
      {:error, _} = err -> err
    end
  end

  @doc """
  Block until the master reaches a usable session state, then return `:ok`.
  """
  @spec await_running(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_running(timeout_ms \\ 10_000), do: Master.await_running(timeout_ms)

  @doc """
  Block until the master reaches operational cyclic runtime, then return `:ok`.
  """
  @spec await_operational(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_operational(timeout_ms \\ 10_000), do: Master.await_operational(timeout_ms)

  @doc """
  Return the current public session state.
  """
  @spec state() :: master_query_result(session_state())
  def state, do: ok_query(Master.state())

  @doc """
  Return the configured slave names for the current session.
  """
  @spec slaves() :: master_query_result([slave_name()])
  def slaves do
    with {:ok, slave_summaries} <- ok_query(Master.slaves()) do
      {:ok, Enum.map(slave_summaries, & &1.name)}
    end
  end

  @doc """
  Return the latest driver-backed aggregate snapshot for all configured slaves.

  Keys:
    - `:cycle` - latest observed cycle counter across active domains, or `nil`
    - `:slaves` - current slave snapshots keyed by slave name
    - `:updated_at_us` - latest slave update timestamp contributing to the image
  """
  @spec snapshot() :: master_query_result(snapshot())
  def snapshot do
    with {:ok, slave_summaries} <- ok_query(Master.slaves()),
         {:ok, slaves} <- snapshot_slaves(slave_summaries) do
      {:ok, Snapshot.from_slaves(snapshot_cycle(), slaves)}
    end
  end

  @doc """
  Return the latest driver-backed snapshot for one named slave.
  """
  @spec snapshot(slave_name()) ::
          {:ok, slave_snapshot()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def snapshot(slave_name) when is_atom(slave_name), do: Slave.snapshot(slave_name)

  @doc """
  Return the effective public description for one named slave.
  """
  @spec describe(slave_name()) ::
          {:ok, description()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def describe(slave_name) when is_atom(slave_name) do
    with {:ok, %SlaveSnapshot{} = snapshot} <- snapshot(slave_name) do
      {:ok, SlaveDescription.from_snapshot(snapshot)}
    end
  end

  @doc """
  Return the effective public descriptions for all configured slaves.
  """
  @spec inventory() :: master_query_result(inventory())
  def inventory do
    with {:ok, %Snapshot{slaves: slaves}} <- snapshot() do
      {:ok,
       Map.new(slaves, fn {name, snapshot} -> {name, SlaveDescription.from_snapshot(snapshot)} end)}
    end
  end

  @doc """
  Subscribe to public driver-backed slave events.

  `subscribe(:all, pid)` follows the runtime-wide slave event stream,
  including future slaves that appear after the subscription is created.

  `subscribe(slave_name, pid)` subscribes only to one named slave's events.

  Returns `{:error, :not_started}` if the application supervision tree is not
  running.

  Event messages are emitted as `%EtherCAT.Event{}` structs.
  """
  @spec subscribe(atom() | :all, pid()) :: :ok | {:error, term()}
  def subscribe(slave_name \\ :all, pid \\ self())

  def subscribe(:all, pid) when is_pid(pid), do: register_subscription(pid, :all)

  def subscribe(slave_name, pid) when is_atom(slave_name) and is_pid(pid),
    do: register_subscription(pid, {:slave, slave_name})

  @doc """
  Execute one driver-backed command against a named slave.

  For generic output writes, prefer
  `EtherCAT.command(slave, :set_output, %{endpoint: endpoint_name, value: value})`.
  The runtime resolves the effective public endpoint name back to the
  driver's native backing signal before invoking the driver callback.
  """
  @spec command(slave_name(), atom(), map()) :: {:ok, reference()} | {:error, term()}
  def command(slave_name, command_name, args)
      when is_atom(slave_name) and is_atom(command_name) and is_map(args) do
    Slave.command(slave_name, command_name, args)
  end

  defp ok_query({:error, _} = err), do: err
  defp ok_query(value), do: {:ok, value}

  defp register_subscription(pid, key) when is_pid(pid) do
    case Process.whereis(EtherCAT.SubscriptionRegistry) do
      nil ->
        {:error, :not_started}

      _registry_pid ->
        case Registry.register(EtherCAT.SubscriptionRegistry, key, true) do
          {:ok, _owner} -> :ok
          {:error, {:already_registered, _owner}} -> :ok
        end
    end
  end

  defp snapshot_slaves(slave_summaries) do
    Enum.reduce_while(slave_summaries, {:ok, %{}}, fn %{name: name}, {:ok, acc} ->
      case Slave.snapshot(name) do
        {:ok, %EtherCAT.SlaveSnapshot{} = snapshot} ->
          {:cont, {:ok, Map.put(acc, name, snapshot)}}

        {:error, reason} ->
          {:halt, {:error, {:snapshot_failed, name, reason}}}
      end
    end)
  end

  defp snapshot_cycle do
    case Master.domains() do
      domains when is_list(domains) ->
        domains
        |> Enum.reduce([], fn {domain_id, _cycle_time_us, _pid}, acc ->
          case Domain.info(domain_id) do
            {:ok, %{cycle_count: cycle_count}} when is_integer(cycle_count) ->
              [cycle_count | acc]

            _ ->
              acc
          end
        end)
        |> case do
          [] -> nil
          cycle_counts -> Enum.max(cycle_counts)
        end

      _ ->
        nil
    end
  end
end
