defmodule EtherCAT.Slave.API do
  @moduledoc """
  Low-level synchronous facade for named `EtherCAT.Slave` processes.

  This module keeps direct registry/call wrappers out of `EtherCAT.Slave` so the
  slave state-machine module can stay focused on ESM states and transitions.
  """

  @spec subscribe(atom(), atom(), pid()) :: :ok | {:error, :not_found | :timeout}
  def subscribe(slave_name, signal_name, pid) do
    safe_call(slave_name, {:subscribe, signal_name, pid})
  end

  @spec write_output(atom(), atom(), term()) :: :ok | {:error, term()}
  def write_output(slave_name, signal_name, value) do
    safe_call(slave_name, {:write_output, signal_name, value})
  end

  @spec request(atom(), atom()) :: :ok | {:error, term()}
  def request(slave_name, target) do
    safe_call(slave_name, {:request, target})
  end

  @spec authorize_reconnect(atom()) :: :ok | {:error, term()}
  def authorize_reconnect(slave_name), do: safe_call(slave_name, :authorize_reconnect)

  @spec configure(atom(), keyword()) :: :ok | {:error, term()}
  def configure(slave_name, opts) when is_list(opts) do
    safe_call(slave_name, {:configure, opts})
  end

  @spec state(atom()) :: atom() | {:error, :not_found | :timeout}
  def state(slave_name), do: safe_call(slave_name, :state)

  @spec identity(atom()) :: map() | nil | {:error, :not_found | :timeout}
  def identity(slave_name), do: safe_call(slave_name, :identity)

  @spec error(atom()) :: non_neg_integer() | nil | {:error, :not_found | :timeout}
  def error(slave_name), do: safe_call(slave_name, :error)

  @spec info(atom()) :: {:ok, map()} | {:error, :not_found | :timeout}
  def info(slave_name), do: safe_call(slave_name, :info)

  @spec read_input(atom(), atom()) :: {:ok, {term(), integer()}} | {:error, term()}
  def read_input(slave_name, signal_name) do
    safe_call(slave_name, {:read_input, signal_name})
  end

  @spec download_sdo(atom(), non_neg_integer(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def download_sdo(slave_name, index, subindex, data)
      when is_binary(data) and byte_size(data) > 0 do
    safe_call(slave_name, {:download_sdo, index, subindex, data})
  end

  @spec upload_sdo(atom(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def upload_sdo(slave_name, index, subindex) do
    safe_call(slave_name, {:upload_sdo, index, subindex})
  end

  defp safe_call(slave_name, msg) do
    try do
      :gen_statem.call(via(slave_name), msg)
    catch
      :exit, {:noproc, _} -> {:error, :not_found}
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  defp via(slave_name), do: {:via, Registry, {EtherCAT.Registry, {:slave, slave_name}}}
end
