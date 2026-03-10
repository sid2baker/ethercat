defmodule EtherCAT.Domain.API do
  @moduledoc """
  Low-level control facade for named `EtherCAT.Domain` processes and their
  direct ETS-backed process image.

  This module keeps public domain calls out of `EtherCAT.Domain` so the state
  machine file can stay focused on domain states and transitions.
  """

  alias EtherCAT.Domain.Image

  @type domain_id :: EtherCAT.Domain.domain_id()
  @type pdo_key :: EtherCAT.Domain.pdo_key()

  @spec register_pdo(domain_id(), pdo_key(), pos_integer(), :input | :output) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def register_pdo(domain_id, key, size, direction) do
    safe_call(domain_id, {:register_pdo, key, size, direction})
  end

  @spec start_cycling(domain_id()) :: :ok | {:error, term()}
  def start_cycling(domain_id), do: safe_call(domain_id, :start_cycling)

  @spec stop_cycling(domain_id()) :: :ok | {:error, :not_found}
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

  @spec stats(domain_id()) :: {:ok, map()} | {:error, :not_found}
  def stats(domain_id), do: safe_call(domain_id, :stats)

  @spec info(domain_id()) :: {:ok, map()} | {:error, :not_found}
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
      :exit, {:noproc, _} -> {:error, :not_found}
    end
  end

  defp via(domain_id), do: {:via, Registry, {EtherCAT.Registry, {:domain, domain_id}}}
end
