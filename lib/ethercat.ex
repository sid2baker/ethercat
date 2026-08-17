defmodule EtherCAT do
  @moduledoc """
  Public runtime API for the EtherCAT protocol boundary.

  Normal applications interact with EtherCAT through lifecycle operations,
  coherent process-data samples, static slave descriptions, and explicit
  protocol writes:

  - `start/1`, `stop/0`, `state/0`
  - `slaves/0`, `describe/1`, `inventory/0`
  - `samples/1`, `sample/2`, `subscribe/2`
  - `read/2`, `write/3`

  A `%EtherCAT.Sample{}` is a coherent decoded observation from one domain
  cycle. It is protocol truth, not projected machine state. Different domains
  do not share a consistency boundary.

  Semantic commands, machine state, and machine events belong above this
  library in an integration such as an `Entity.Provider`.

  Specialist APIs live under:

  - `EtherCAT.Provisioning` for PREOP configuration, activation, and SDO traffic
  - `EtherCAT.Diagnostics` for DC, slave, domain, and topology inspection
  - `EtherCAT.Raw` for direct PDO and latch access
  - `EtherCAT.Driver` for protocol/device driver authors
  - `EtherCAT.Simulator` for testing and simulator workflows

  Host applications must supervise `EtherCAT.Runtime` before calling this API.
  `start/1` and `stop/0` control the singleton session inside that host-owned
  runtime; they do not boot the supervision tree themselves.
  """

  alias EtherCAT.Master
  alias EtherCAT.Sample
  alias EtherCAT.Slave
  alias EtherCAT.SlaveDescription

  @type session_state ::
          :idle
          | :discovering
          | :awaiting_preop
          | :preop_ready
          | :deactivated
          | :operational
          | :activation_blocked
          | :recovering

  @type master_query_error :: {:error, :not_started | :timeout | {:server_exit, term()}}
  @type master_query_result(value) :: {:ok, value} | master_query_error()
  @type slave_name :: atom()
  @type domain_id :: atom()
  @type description :: SlaveDescription.t()
  @type inventory :: %{optional(slave_name()) => description()}
  @type sample_map :: %{optional(domain_id()) => Sample.t()}

  @doc """
  Start the master: open the backend, discover slaves, and begin configuration.
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: Master.start(opts)

  @doc "Stop the active master session."
  @spec stop() :: :ok | {:error, :already_stopped | :timeout | {:server_exit, term()}}
  def stop do
    case Master.stop() do
      :ok -> :ok
      :already_stopped -> {:error, :already_stopped}
      {:error, _} = error -> error
    end
  end

  @doc "Block until the master reaches a usable session state."
  @spec await_running(pos_integer()) :: :ok | {:error, term()}
  def await_running(timeout_ms \\ 10_000), do: Master.await_running(timeout_ms)

  @doc "Block until the master reaches operational cyclic runtime."
  @spec await_operational(pos_integer()) :: :ok | {:error, term()}
  def await_operational(timeout_ms \\ 10_000), do: Master.await_operational(timeout_ms)

  @doc "Return the current public session state."
  @spec state() :: master_query_result(session_state())
  def state, do: ok_query(Master.state())

  @doc "Return the configured slave names for the current session."
  @spec slaves() :: master_query_result([slave_name()])
  def slaves do
    with {:ok, slave_summaries} <- ok_query(Master.slaves()) do
      {:ok, Enum.map(slave_summaries, & &1.name)}
    end
  end

  @doc "Return the latest retained domain samples for one slave."
  @spec samples(slave_name()) ::
          {:ok, sample_map()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def samples(slave_name) when is_atom(slave_name), do: Slave.samples(slave_name)

  @doc "Return the latest retained sample for one slave and domain."
  @spec sample(slave_name(), domain_id()) ::
          {:ok, Sample.t()}
          | {:error, :not_ready | :not_found | :timeout | {:server_exit, term()}}
  def sample(slave_name, domain_id) when is_atom(slave_name) and is_atom(domain_id) do
    with {:ok, samples} <- Slave.samples(slave_name) do
      case Map.fetch(samples, domain_id) do
        {:ok, sample} -> {:ok, sample}
        :error -> {:error, :not_ready}
      end
    end
  end

  @doc "Return the static protocol description for one configured slave."
  @spec describe(slave_name()) ::
          {:ok, description()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def describe(slave_name) when is_atom(slave_name) do
    with {:ok, status} <- configured_status(),
         {:ok, configured_slave} <- configured_slave(status, slave_name) do
      {:ok, SlaveDescription.from_configured_slave(configured_slave)}
    end
  end

  @doc "Return static protocol descriptions for all configured slaves."
  @spec inventory() :: master_query_result(inventory())
  def inventory do
    with {:ok, status} <- configured_status() do
      {:ok,
       Map.new(status.configured_slaves, fn configured_slave ->
         {configured_slave.name, SlaveDescription.from_configured_slave(configured_slave)}
       end)}
    end
  end

  @doc """
  Subscribe a process to coherent samples from one slave.

  Registration and the returned current sample map share the slave process's
  serialization boundary. Subsequent observations are delivered directly as
  `%EtherCAT.Sample{}` messages. Subscriber processes are monitored and cleaned
  up automatically.
  """
  @spec subscribe(slave_name(), pid()) ::
          {:ok, sample_map()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def subscribe(slave_name, pid \\ self()) when is_atom(slave_name) and is_pid(pid) do
    Slave.subscribe_samples(slave_name, pid)
  end

  @doc "Read one decoded input signal from the current process image."
  @spec read(slave_name(), atom()) :: {:ok, {term(), integer()}} | {:error, term()}
  def read(slave_name, signal_name) when is_atom(slave_name) and is_atom(signal_name) do
    Slave.read_input(slave_name, signal_name)
  end

  @doc "Stage one decoded output signal for the next domain cycle."
  @spec write(slave_name(), atom(), term()) :: :ok | {:error, term()}
  def write(slave_name, signal_name, value)
      when is_atom(slave_name) and is_atom(signal_name) do
    Slave.write_output(slave_name, signal_name, value)
  end

  defp ok_query({:error, _} = error), do: error
  defp ok_query(value), do: {:ok, value}

  defp configured_status do
    case Master.status() do
      %EtherCAT.Master.Status{lifecycle: lifecycle} when lifecycle in [:stopped, :idle] ->
        {:error, :not_started}

      %EtherCAT.Master.Status{} = status ->
        {:ok, status}

      {:error, _} = error ->
        error
    end
  end

  defp configured_slave(%EtherCAT.Master.Status{configured_slaves: configured_slaves}, slave_name) do
    case Enum.find(configured_slaves, &(&1.name == slave_name)) do
      nil -> {:error, :not_found}
      slave -> {:ok, slave}
    end
  end
end
