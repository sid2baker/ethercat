defmodule EtherCAT do
  @moduledoc """
  Public runtime API for the EtherCAT protocol boundary.

  `start/1` returns an opaque `%EtherCAT.Session{}`. Every runtime operation
  requires that session, so a caller can never cross a stop/start boundary by
  resolving through the current singleton runtime:

      {:ok, session} = EtherCAT.start(backend: {:raw, %{interface: "eth0"}})
      :ok = EtherCAT.await_operational(session)
      {:ok, sample} = EtherCAT.sample(session, :inputs, :io)

  A stopped or replaced session returns `{:error, :stale_session}`.

  Normal applications interact with EtherCAT through lifecycle operations,
  coherent process-data samples, static slave descriptions, protocol status,
  notifications, and explicit protocol writes.

  A `%EtherCAT.Sample{}` is a coherent decoded observation from one domain
  cycle. It is protocol truth, not projected machine state. Different domains
  do not share a consistency boundary.

  Semantic commands, machine state, and machine events belong above this
  library in a separate integration such as an `Entity.Provider`.

  Specialist APIs live under:

  - `EtherCAT.Provisioning` for PREOP configuration, activation, and SDO traffic
  - `EtherCAT.Diagnostics` for DC, slave, domain, and topology inspection
  - `EtherCAT.Raw` for direct PDO and latch access
  - `EtherCAT.Driver` for protocol/device driver authors
  - `EtherCAT.Simulator` for testing and simulator workflows

  Host applications must supervise `EtherCAT.Runtime` before calling this API.
  `start/1` and `stop/1` control one session inside that host-owned runtime;
  they do not boot the supervision tree themselves.
  """

  alias EtherCAT.Master
  alias EtherCAT.Sample
  alias EtherCAT.Session
  alias EtherCAT.Slave
  alias EtherCAT.SlaveDescription

  @type session_state ::
          :discovering
          | :awaiting_preop
          | :preop_ready
          | :deactivated
          | :operational
          | :activation_blocked
          | :recovering

  @type session :: Session.t()
  @type session_query_error ::
          {:error, :not_started | :stale_session | :timeout | {:server_exit, term()}}
  @type session_query_result(value) :: {:ok, value} | session_query_error()
  @type slave_name :: atom()
  @type domain_id :: atom()
  @type description :: SlaveDescription.t()
  @type inventory :: %{optional(slave_name()) => description()}
  @type sample_map :: %{optional(domain_id()) => Sample.t()}
  @type slave_status :: EtherCAT.Slave.Status.t()

  @doc "Start a master session and return its opaque identity."
  @spec start(keyword()) :: {:ok, Session.t()} | {:error, term()}
  def start(opts \\ []) do
    case Master.start_session(opts) do
      {:ok, generation, master} -> {:ok, Session.new(master, generation)}
      {:error, _reason} = error -> error
    end
  end

  @doc "Stop exactly `session`."
  @spec stop(Session.t()) :: :ok | {:error, term()}
  def stop(session) do
    session
    |> Session.call(:stop)
    |> normalize_stop_reply()
  end

  @doc "Block until `session` reaches a usable state."
  @spec await_running(Session.t(), pos_integer()) :: :ok | {:error, term()}
  def await_running(session, timeout_ms \\ 10_000)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    Session.call(session, :await_running, wait_call_timeout(timeout_ms))
  end

  @doc "Block until `session` reaches operational cyclic runtime."
  @spec await_operational(Session.t(), pos_integer()) :: :ok | {:error, term()}
  def await_operational(session, timeout_ms \\ 10_000)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    Session.call(session, :await_operational, wait_call_timeout(timeout_ms))
  end

  @doc "Return the session lifecycle state."
  @spec state(Session.t()) :: session_query_result(session_state())
  def state(session), do: ok_query(Session.call(session, :state))

  @doc "Return configured slave names for the session."
  @spec slaves(Session.t()) :: session_query_result([slave_name()])
  def slaves(session), do: slave_names(Session.call(session, :slaves))

  @doc "Return current protocol/runtime status for one slave."
  @spec status(Session.t(), slave_name()) :: {:ok, slave_status()} | {:error, term()}
  def status(session, slave_name) when is_atom(slave_name) do
    with {:ok, slave} <- Session.slave(session, slave_name) do
      Slave.status(slave)
    end
  end

  @doc "Return the latest retained domain samples for one slave."
  @spec samples(Session.t(), slave_name()) :: {:ok, sample_map()} | {:error, term()}
  def samples(session, slave_name) when is_atom(slave_name) do
    with {:ok, slave} <- Session.slave(session, slave_name) do
      Slave.samples(slave)
    end
  end

  @doc "Return the latest retained sample for one slave and domain."
  @spec sample(Session.t(), slave_name(), domain_id()) ::
          {:ok, Sample.t()} | {:error, term()}
  def sample(session, slave_name, domain_id)
      when is_atom(slave_name) and is_atom(domain_id) do
    session
    |> samples(slave_name)
    |> sample_from_samples(domain_id)
  end

  @doc "Return the static protocol description for one slave."
  @spec describe(Session.t(), slave_name()) :: {:ok, description()} | {:error, term()}
  def describe(session, slave_name) when is_atom(slave_name) do
    with {:ok, configured_slave} <- Session.call(session, {:slave_configuration, slave_name}) do
      {:ok, SlaveDescription.from_configured_slave(configured_slave)}
    end
  end

  @doc "Return static protocol descriptions for the session."
  @spec inventory(Session.t()) :: session_query_result(inventory())
  def inventory(session) do
    with {:ok, configs} <- Session.call(session, :slave_configurations) do
      {:ok, Map.new(configs, &{&1.name, SlaveDescription.from_configured_slave(&1)})}
    end
  end

  @doc """
  Subscribe a process to protocol observations from one slave.

  Registration and the returned status/sample values share the slave process's
  serialization boundary. Subsequent observations arrive as
  `%EtherCAT.Sample{}` and `%EtherCAT.Notification{}` messages.
  """
  @spec subscribe(Session.t(), slave_name(), pid()) ::
          {:ok, slave_status(), sample_map()} | {:error, term()}
  def subscribe(session, slave_name, pid \\ self())
      when is_atom(slave_name) and is_pid(pid) do
    with {:ok, slave} <- Session.slave(session, slave_name) do
      Slave.subscribe_protocol(slave, pid)
    end
  end

  @doc "Read one decoded input signal from the session's process image."
  @spec read(Session.t(), slave_name(), atom()) ::
          {:ok, {term(), integer()}} | {:error, term()}
  def read(session, slave_name, signal_name)
      when is_atom(slave_name) and is_atom(signal_name) do
    with {:ok, slave} <- Session.slave(session, slave_name) do
      Slave.read_input(slave, signal_name)
    end
  end

  @doc "Stage one decoded output signal for the session's next domain cycle."
  @spec write(Session.t(), slave_name(), atom(), term()) :: :ok | {:error, term()}
  def write(session, slave_name, signal_name, value)
      when is_atom(slave_name) and is_atom(signal_name) do
    with {:ok, slave} <- Session.slave(session, slave_name) do
      Slave.write_output(slave, signal_name, value)
    end
  end

  defp normalize_stop_reply(:ok), do: :ok
  defp normalize_stop_reply({:error, _reason} = error), do: error

  defp sample_from_samples({:ok, samples}, domain_id) do
    case Map.fetch(samples, domain_id) do
      {:ok, sample} -> {:ok, sample}
      :error -> {:error, :not_ready}
    end
  end

  defp sample_from_samples({:error, _reason} = error, _domain_id), do: error

  defp slave_names({:error, _reason} = error), do: error
  defp slave_names(slaves), do: {:ok, Enum.map(slaves, & &1.name)}

  defp ok_query({:error, _reason} = error), do: error
  defp ok_query(value), do: {:ok, value}

  defp wait_call_timeout(timeout_ms), do: timeout_ms + min(max(div(timeout_ms, 20), 10), 100)
end
