defmodule EtherCAT.Domain do
  @moduledoc """
  Cyclic process image for one logical EtherCAT domain.

  One domain runs per configured domain ID. Slaves register their PDO layout
  during PREOP, then the domain runs a self-timed LRW exchange each cycle.

  `EtherCAT.Domain` is the public boundary for domain lifecycle and process
  image access. The domain process owns the open, cycling, and stopped states.
  The hot-path image API is intentionally separate: `write/3`, `read/2`, and
  `sample/2` access the ETS-backed process image directly instead of going
  through synchronous state-machine calls.

  ## States

  - `:open` - accepting PDO registrations, not yet cycling
  - `:cycling` - self-timed LRW tick active
  - `:stopped` - cycling halted by manual stop or miss threshold

  ## State transitions

  ```mermaid
  stateDiagram-v2
      [*] --> open
      open --> cycling: start_cycling and layout preparation succeed
      cycling --> stopped: stop_cycling or miss threshold is reached
      stopped --> cycling: start_cycling
  ```

  Within `:cycling`, cycle health is tracked separately as runtime data:

  - `:healthy` - the latest LRW cycle was valid
  - `{:invalid, reason}` - the latest LRW cycle had a transport miss or unusable reply
  """

  alias EtherCAT.Domain.FSM
  alias EtherCAT.Domain.Image
  alias EtherCAT.Domain.Layout
  alias EtherCAT.Utils

  @type domain_id :: atom()
  @type pdo_key :: {slave_name :: atom(), pdo_name :: atom()}

  defstruct [
    :id,
    :bus,
    :period_us,
    :logical_base,
    :next_cycle_at,
    :last_cycle_started_at_us,
    :last_cycle_completed_at_us,
    :last_valid_cycle_at_us,
    :last_invalid_cycle_at_us,
    :last_invalid_reason,
    layout: Layout.new(),
    cycle_plan: nil,
    cycle_health: :healthy,
    miss_count: 0,
    miss_threshold: 100,
    cycle_count: 0,
    total_miss_count: 0,
    table: nil
  ]

  @doc false
  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {__MODULE__, id},
      start: {FSM, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5000
    }
  end

  @doc false
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts), do: FSM.start_link(opts)

  @doc """
  Register one PDO entry in the domain layout while the domain is open.

  Returns the assigned logical byte offset relative to the domain base.
  """
  @spec register_pdo(domain_id(), pdo_key(), pos_integer(), :input | :output) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def register_pdo(domain_id, key, size, direction) do
    safe_call(domain_id, {:register_pdo, key, size, direction})
  end

  @doc """
  Start cyclic LRW exchange for the domain.
  """
  @spec start_cycling(domain_id()) :: :ok | {:error, term()}
  def start_cycling(domain_id), do: safe_call(domain_id, :start_cycling)

  @doc """
  Stop cyclic LRW exchange for the domain.

  The process image remains available after the domain stops.
  """
  @spec stop_cycling(domain_id()) ::
          :ok | {:error, :not_found | :timeout | {:server_exit, term()}}
  def stop_cycling(domain_id), do: safe_call(domain_id, :stop_cycling)

  @doc """
  Stage an output binary into the domain process image.

  This is a direct ETS-backed hot-path write and does not go through the domain
  process mailbox.
  """
  @spec write(domain_id(), pdo_key(), binary()) :: :ok | {:error, :not_found}
  def write(domain_id, key, binary) when is_atom(domain_id) and is_binary(binary) do
    updated_at_us = System.monotonic_time(:microsecond)

    with {:ok, table} <- Image.lookup_table(domain_id) do
      Image.write(table, key, binary, updated_at_us)
    end
  end

  @doc """
  Read the current process-image value for one PDO key.

  Returns `{:error, :not_ready}` until an input has been populated or an output
  has been staged.
  """
  @spec read(domain_id(), pdo_key()) :: {:ok, binary()} | {:error, :not_found | :not_ready}
  def read(domain_id, key) when is_atom(domain_id) do
    with {:ok, table} <- Image.lookup_table(domain_id) do
      case Image.read(table, key) do
        {:ok, :unset} -> {:error, :not_ready}
        {:ok, value} -> {:ok, value}
        {:error, :not_found} -> {:error, :not_found}
      end
    end
  end

  @doc """
  Read the current process-image value plus freshness metadata for one PDO key.
  """
  @spec sample(domain_id(), pdo_key()) ::
          {:ok, %{value: binary(), updated_at_us: integer() | nil}}
          | {:error, :not_found | :not_ready}
  def sample(domain_id, key) when is_atom(domain_id) do
    with {:ok, table} <- Image.lookup_table(domain_id) do
      Image.sample(table, key)
    end
  end

  @doc """
  Return a compact runtime statistics snapshot for the domain.
  """
  @spec stats(domain_id()) ::
          {:ok, map()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def stats(domain_id), do: safe_call(domain_id, :stats)

  @doc """
  Return a detailed runtime snapshot for the domain.
  """
  @spec info(domain_id()) ::
          {:ok, map()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def info(domain_id), do: safe_call(domain_id, :info)

  @doc """
  Update the live cycle period for the running domain.
  """
  @spec update_cycle_time(domain_id(), pos_integer()) :: :ok | {:error, term()}
  def update_cycle_time(domain_id, cycle_time_us)
      when is_integer(cycle_time_us) and cycle_time_us > 0 do
    safe_call(domain_id, {:update_cycle_time, cycle_time_us})
  end

  defp safe_call(domain_id, msg) do
    try do
      :gen_statem.call(via(domain_id), msg)
    catch
      :exit, reason -> Utils.classify_call_exit(reason, :not_found)
    end
  end

  defp via(domain_id), do: {:via, Registry, {EtherCAT.Registry, {:domain, domain_id}}}
end
