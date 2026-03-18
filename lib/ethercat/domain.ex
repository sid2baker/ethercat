defmodule EtherCAT.Domain do
  @moduledoc File.read!(Path.join(__DIR__, "domain.md"))

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

  @spec register_pdo(domain_id(), pdo_key(), pos_integer(), :input | :output) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def register_pdo(domain_id, key, size, direction) do
    safe_call(domain_id, {:register_pdo, key, size, direction})
  end

  @spec start_cycling(domain_id()) :: :ok | {:error, term()}
  def start_cycling(domain_id), do: safe_call(domain_id, :start_cycling)

  @spec stop_cycling(domain_id()) ::
          :ok | {:error, :not_found | :timeout | {:server_exit, term()}}
  def stop_cycling(domain_id), do: safe_call(domain_id, :stop_cycling)

  @spec write(domain_id(), pdo_key(), binary()) :: :ok | {:error, :not_found}
  def write(domain_id, key, binary) when is_atom(domain_id) and is_binary(binary) do
    updated_at_us = System.monotonic_time(:microsecond)

    try do
      Image.write(domain_id, key, binary, updated_at_us)
    rescue
      ArgumentError -> {:error, :not_found}
    end
  end

  @spec read(domain_id(), pdo_key()) :: {:ok, binary()} | {:error, :not_found | :not_ready}
  def read(domain_id, key) when is_atom(domain_id) do
    try do
      case Image.read(domain_id, key) do
        {:ok, :unset} -> {:error, :not_ready}
        {:ok, value} -> {:ok, value}
        :error -> {:error, :not_found}
      end
    rescue
      ArgumentError -> {:error, :not_found}
    end
  end

  @spec sample(domain_id(), pdo_key()) ::
          {:ok, %{value: binary(), updated_at_us: integer() | nil}}
          | {:error, :not_found | :not_ready}
  def sample(domain_id, key) when is_atom(domain_id) do
    try do
      Image.sample(domain_id, key)
    rescue
      ArgumentError -> {:error, :not_found}
    end
  end

  @spec stats(domain_id()) ::
          {:ok, map()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def stats(domain_id), do: safe_call(domain_id, :stats)

  @spec info(domain_id()) ::
          {:ok, map()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def info(domain_id), do: safe_call(domain_id, :info)

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
