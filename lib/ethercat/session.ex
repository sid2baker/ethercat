defmodule EtherCAT.Session do
  @moduledoc """
  Opaque identity for one started EtherCAT session.

  A session is bound to both the master process and one generation of that
  process. It is the required capability for runtime, provisioning,
  diagnostics, signal subscription, and live capture operations.

  Once stopped or replaced, operations made with the old session return
  `{:error, :stale_session}` rather than targeting a replacement session.
  """

  @opaque t :: %__MODULE__{master: pid(), generation: reference()}

  alias EtherCAT.Utils

  @call_timeout_ms 5_000

  @enforce_keys [:master, :generation]
  defstruct [:master, :generation]

  @doc false
  @spec new(pid(), reference()) :: t()
  def new(master, generation) when is_pid(master) and is_reference(generation) do
    %__MODULE__{master: master, generation: generation}
  end

  @doc false
  @spec master(t()) :: pid()
  def master(%__MODULE__{master: master}), do: master

  @doc false
  @spec generation(t()) :: reference()
  def generation(%__MODULE__{generation: generation}), do: generation

  @doc "Return the currently active session identity for explicit host tooling."
  @spec current() :: {:ok, t()} | {:error, term()}
  def current do
    case Process.whereis(EtherCAT.Master) do
      nil ->
        {:error, :not_started}

      master ->
        case Utils.statem_call(master, :session_identity, :not_started, @call_timeout_ms) do
          {:ok, generation} -> {:ok, new(master, generation)}
          {:error, _reason} = error -> error
        end
    end
  end

  @doc false
  @spec call(t(), term(), timeout()) :: term()
  def call(%__MODULE__{} = session, message, timeout \\ @call_timeout_ms) do
    Utils.statem_call(
      master(session),
      {:session, generation(session), message},
      :stale_session,
      timeout
    )
  end

  @doc false
  @spec slave(t(), atom()) :: {:ok, pid()} | {:error, term()}
  def slave(%__MODULE__{} = session, slave_name) when is_atom(slave_name) do
    call(session, {:resolve_slave, slave_name})
  end

  @doc false
  @spec domain(t(), atom()) :: {:ok, pid()} | {:error, term()}
  def domain(%__MODULE__{} = session, domain_id) when is_atom(domain_id) do
    call(session, {:resolve_domain, domain_id})
  end
end
