defmodule EtherCAT do
  @moduledoc """
  Public runtime API for the EtherCAT protocol boundary.

  `start/1` returns a `%EtherCAT.Runtime.Handle{}` bound to one master
  process and one session generation. Long-lived integrations should pass that
  handle to subsequent operations so a stopped session can never be confused
  with its replacement:

      {:ok, ethercat} = EtherCAT.start(backend: {:raw, %{interface: "eth0"}})
      :ok = EtherCAT.await_operational(ethercat)
      {:ok, sample} = EtherCAT.sample(ethercat, :inputs, :io)

  Handle-free variants remain the host-facing convenience surface for the
  current singleton runtime. They are useful for startup tooling and
  diagnostics, but integrations that retain EtherCAT ownership should use the
  handle-bound variants.

  Normal applications interact with EtherCAT through lifecycle operations,
  coherent process-data samples, static slave descriptions, protocol status,
  notifications, and explicit protocol writes.

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
  `start/1` and `stop/1` control the singleton session inside that host-owned
  runtime; they do not boot the supervision tree themselves.
  """

  alias EtherCAT.Master
  alias EtherCAT.Runtime.Handle
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

  @type handle :: Handle.t()
  @type master_query_error ::
          {:error, :not_started | :stale_handle | :timeout | {:server_exit, term()}}
  @type master_query_result(value) :: {:ok, value} | master_query_error()
  @type slave_name :: atom()
  @type domain_id :: atom()
  @type description :: SlaveDescription.t()
  @type inventory :: %{optional(slave_name()) => description()}
  @type sample_map :: %{optional(domain_id()) => Sample.t()}
  @type slave_status :: EtherCAT.Slave.Status.t()

  @doc """
  Start a master session and return its generation-bound runtime handle.
  """
  @spec start(keyword()) :: {:ok, Handle.t()} | {:error, term()}
  def start(opts \\ []) do
    case Master.start_session(opts) do
      {:ok, session, master} -> {:ok, Handle.new(master, session)}
      {:error, _reason} = error -> error
    end
  end

  @doc "Stop the current singleton master session."
  @spec stop() :: :ok | {:error, :already_stopped | :timeout | {:server_exit, term()}}
  def stop do
    normalize_stop_reply(Master.stop())
  end

  @doc "Stop the session identified by `handle`."
  @spec stop(Handle.t()) :: :ok | {:error, term()}
  def stop(%Handle{} = handle) do
    handle
    |> Master.session_call(:stop)
    |> normalize_stop_reply()
  end

  @doc "Block until the current singleton session reaches a usable state."
  @spec await_running() :: :ok | {:error, term()}
  def await_running, do: Master.await_running()

  @doc """
  Block until the handled session reaches a usable state, or use an integer
  timeout with the current singleton session.
  """
  @spec await_running(Handle.t()) :: :ok | {:error, term()}
  def await_running(%Handle{} = handle), do: await_running(handle, 10_000)

  @spec await_running(pos_integer()) :: :ok | {:error, term()}
  def await_running(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    Master.await_running(timeout_ms)
  end

  @doc "Block until the handled session reaches a usable state."
  @spec await_running(Handle.t(), pos_integer()) :: :ok | {:error, term()}
  def await_running(%Handle{} = handle, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    Master.session_call(handle, :await_running, wait_call_timeout(timeout_ms))
  end

  @doc "Block until the current singleton session reaches operational cyclic runtime."
  @spec await_operational() :: :ok | {:error, term()}
  def await_operational, do: Master.await_operational()

  @doc """
  Block until the handled session reaches operational cyclic runtime, or use
  an integer timeout with the current singleton session.
  """
  @spec await_operational(Handle.t()) :: :ok | {:error, term()}
  def await_operational(%Handle{} = handle), do: await_operational(handle, 10_000)

  @spec await_operational(pos_integer()) :: :ok | {:error, term()}
  def await_operational(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    Master.await_operational(timeout_ms)
  end

  @doc "Block until the handled session reaches operational cyclic runtime."
  @spec await_operational(Handle.t(), pos_integer()) :: :ok | {:error, term()}
  def await_operational(%Handle{} = handle, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    Master.session_call(handle, :await_operational, wait_call_timeout(timeout_ms))
  end

  @doc "Return the current singleton session state."
  @spec state() :: master_query_result(session_state())
  def state, do: ok_query(Master.state())

  @doc "Return the handled session state."
  @spec state(Handle.t()) :: master_query_result(session_state())
  def state(%Handle{} = handle), do: ok_query(Master.session_call(handle, :state))

  @doc "Return configured slave names for the current singleton session."
  @spec slaves() :: master_query_result([slave_name()])
  def slaves, do: slave_names(Master.slaves())

  @doc "Return configured slave names for the handled session."
  @spec slaves(Handle.t()) :: master_query_result([slave_name()])
  def slaves(%Handle{} = handle), do: slave_names(Master.session_call(handle, :slaves))

  @doc "Return current protocol/runtime status for one slave in the current session."
  @spec status(slave_name()) ::
          {:ok, slave_status()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def status(slave_name) when is_atom(slave_name), do: Slave.status(slave_name)

  @doc "Return current protocol/runtime status for one slave in the handled session."
  @spec status(Handle.t(), slave_name()) :: {:ok, slave_status()} | {:error, term()}
  def status(%Handle{} = handle, slave_name) when is_atom(slave_name) do
    with {:ok, slave} <- resolve_slave(handle, slave_name) do
      Slave.status(slave)
    end
  end

  @doc "Return the latest retained domain samples for one slave in the current session."
  @spec samples(slave_name()) ::
          {:ok, sample_map()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def samples(slave_name) when is_atom(slave_name), do: Slave.samples(slave_name)

  @doc "Return the latest retained domain samples for one slave in the handled session."
  @spec samples(Handle.t(), slave_name()) :: {:ok, sample_map()} | {:error, term()}
  def samples(%Handle{} = handle, slave_name) when is_atom(slave_name) do
    with {:ok, slave} <- resolve_slave(handle, slave_name) do
      Slave.samples(slave)
    end
  end

  @doc "Return the latest retained sample for one slave and domain in the current session."
  @spec sample(slave_name(), domain_id()) ::
          {:ok, Sample.t()}
          | {:error, :not_ready | :not_found | :timeout | {:server_exit, term()}}
  def sample(slave_name, domain_id) when is_atom(slave_name) and is_atom(domain_id) do
    sample_from_samples(samples(slave_name), domain_id)
  end

  @doc "Return the latest retained sample for one slave and domain in the handled session."
  @spec sample(Handle.t(), slave_name(), domain_id()) :: {:ok, Sample.t()} | {:error, term()}
  def sample(%Handle{} = handle, slave_name, domain_id)
      when is_atom(slave_name) and is_atom(domain_id) do
    sample_from_samples(samples(handle, slave_name), domain_id)
  end

  @doc "Return the static protocol description for one slave in the current session."
  @spec describe(slave_name()) ::
          {:ok, description()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def describe(slave_name) when is_atom(slave_name) do
    with {:ok, status} <- configured_status(),
         {:ok, configured_slave} <- configured_slave(status, slave_name) do
      {:ok, SlaveDescription.from_configured_slave(configured_slave)}
    end
  end

  @doc "Return the static protocol description for one slave in the handled session."
  @spec describe(Handle.t(), slave_name()) :: {:ok, description()} | {:error, term()}
  def describe(%Handle{} = handle, slave_name) when is_atom(slave_name) do
    with {:ok, status} <- configured_status(handle),
         {:ok, configured_slave} <- configured_slave(status, slave_name) do
      {:ok, SlaveDescription.from_configured_slave(configured_slave)}
    end
  end

  @doc "Return static protocol descriptions for the current singleton session."
  @spec inventory() :: master_query_result(inventory())
  def inventory do
    with {:ok, status} <- configured_status() do
      {:ok, inventory_from_status(status)}
    end
  end

  @doc "Return static protocol descriptions for the handled session."
  @spec inventory(Handle.t()) :: master_query_result(inventory())
  def inventory(%Handle{} = handle) do
    with {:ok, status} <- configured_status(handle) do
      {:ok, inventory_from_status(status)}
    end
  end

  @doc """
  Subscribe a process to protocol observations from one slave in the current session.

  Registration and the returned status/sample values share the slave process's
  serialization boundary. Subsequent observations arrive as
  `%EtherCAT.Sample{}` and `%EtherCAT.Notification{}` messages.
  """
  @spec subscribe(slave_name()) ::
          {:ok, slave_status(), sample_map()} | {:error, term()}
  def subscribe(slave_name) when is_atom(slave_name), do: subscribe(slave_name, self())

  @spec subscribe(slave_name(), pid()) ::
          {:ok, slave_status(), sample_map()} | {:error, term()}
  def subscribe(slave_name, pid) when is_atom(slave_name) and is_pid(pid) do
    Slave.subscribe_protocol(slave_name, pid)
  end

  @doc "Subscribe a process to protocol observations from one slave in the handled session."
  @spec subscribe(Handle.t(), slave_name()) ::
          {:ok, slave_status(), sample_map()} | {:error, term()}
  def subscribe(%Handle{} = handle, slave_name) when is_atom(slave_name) do
    subscribe(handle, slave_name, self())
  end

  @spec subscribe(Handle.t(), slave_name(), pid()) ::
          {:ok, slave_status(), sample_map()} | {:error, term()}
  def subscribe(%Handle{} = handle, slave_name, pid)
      when is_atom(slave_name) and is_pid(pid) do
    with {:ok, slave} <- resolve_slave(handle, slave_name) do
      Slave.subscribe_protocol(slave, pid)
    end
  end

  @doc "Read one decoded input signal from the current session's process image."
  @spec read(slave_name(), atom()) :: {:ok, {term(), integer()}} | {:error, term()}
  def read(slave_name, signal_name) when is_atom(slave_name) and is_atom(signal_name) do
    Slave.read_input(slave_name, signal_name)
  end

  @doc "Read one decoded input signal from the handled session's process image."
  @spec read(Handle.t(), slave_name(), atom()) ::
          {:ok, {term(), integer()}} | {:error, term()}
  def read(%Handle{} = handle, slave_name, signal_name)
      when is_atom(slave_name) and is_atom(signal_name) do
    with {:ok, slave} <- resolve_slave(handle, slave_name) do
      Slave.read_input(slave, signal_name)
    end
  end

  @doc "Stage one decoded output signal for the current session's next domain cycle."
  @spec write(slave_name(), atom(), term()) :: :ok | {:error, term()}
  def write(slave_name, signal_name, value)
      when is_atom(slave_name) and is_atom(signal_name) do
    Slave.write_output(slave_name, signal_name, value)
  end

  @doc "Stage one decoded output signal for the handled session's next domain cycle."
  @spec write(Handle.t(), slave_name(), atom(), term()) :: :ok | {:error, term()}
  def write(%Handle{} = handle, slave_name, signal_name, value)
      when is_atom(slave_name) and is_atom(signal_name) do
    with {:ok, slave} <- resolve_slave(handle, slave_name) do
      Slave.write_output(slave, signal_name, value)
    end
  end

  defp normalize_stop_reply(:ok), do: :ok
  defp normalize_stop_reply(:already_stopped), do: {:error, :already_stopped}
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

  defp resolve_slave(handle, slave_name) do
    case Master.session_call(handle, :slaves) do
      {:error, _reason} = error ->
        error

      slaves ->
        case Enum.find(slaves, &(&1.name == slave_name)) do
          %{pid: pid} when is_pid(pid) -> {:ok, pid}
          _missing -> {:error, :not_found}
        end
    end
  end

  defp ok_query({:error, _reason} = error), do: error
  defp ok_query(value), do: {:ok, value}

  defp configured_status do
    normalize_configured_status(Master.status())
  end

  defp configured_status(handle) do
    handle
    |> Master.session_call(:status)
    |> normalize_configured_status()
  end

  defp normalize_configured_status(%EtherCAT.Master.Status{lifecycle: lifecycle})
       when lifecycle in [:stopped, :idle],
       do: {:error, :not_started}

  defp normalize_configured_status(%EtherCAT.Master.Status{} = status), do: {:ok, status}
  defp normalize_configured_status({:error, _reason} = error), do: error

  defp configured_slave(%EtherCAT.Master.Status{configured_slaves: configured_slaves}, slave_name) do
    case Enum.find(configured_slaves, &(&1.name == slave_name)) do
      nil -> {:error, :not_found}
      slave -> {:ok, slave}
    end
  end

  defp inventory_from_status(status) do
    Map.new(status.configured_slaves, fn configured_slave ->
      {configured_slave.name, SlaveDescription.from_configured_slave(configured_slave)}
    end)
  end

  defp wait_call_timeout(timeout_ms), do: timeout_ms + min(max(div(timeout_ms, 20), 10), 100)
end
