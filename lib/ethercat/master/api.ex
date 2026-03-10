defmodule EtherCAT.Master.API do
  @moduledoc """
  Low-level synchronous facade for the local `EtherCAT.Master` process.

  This module is intentionally thin. It keeps public call wrappers out of
  `EtherCAT.Master` so the state machine file can stay focused on session states
  and transitions.
  """

  alias EtherCAT.Bus
  alias EtherCAT.DC.API, as: DCAPI

  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: safe_call({:start, opts})

  @spec stop() :: :ok | :already_stopped
  def stop do
    try do
      :gen_statem.call(EtherCAT.Master, :stop)
    catch
      :exit, {:noproc, _} -> :already_stopped
    end
  end

  @spec slaves() :: list() | {:error, :not_started}
  def slaves, do: safe_call(:slaves)

  @spec domains() :: list() | {:error, :not_started}
  def domains, do: safe_call(:domains)

  @spec bus() :: Bus.server() | nil | {:error, :not_started}
  def bus, do: safe_call(:bus)

  @spec last_failure() :: map() | nil | {:error, :not_started}
  def last_failure, do: safe_call(:last_failure)

  @spec state() :: atom() | {:error, :not_started}
  def state, do: safe_call(:state)

  @spec configure_slave(atom(), keyword() | EtherCAT.Slave.Config.t()) :: :ok | {:error, term()}
  def configure_slave(slave_name, spec) do
    safe_call({:configure_slave, slave_name, spec})
  end

  @spec activate() :: :ok | {:error, term()}
  def activate, do: safe_call(:activate)

  @spec update_domain_cycle_time(atom(), pos_integer()) :: :ok | {:error, term()}
  def update_domain_cycle_time(domain_id, cycle_time_us)
      when is_atom(domain_id) and is_integer(cycle_time_us) and cycle_time_us > 0 do
    safe_call({:update_domain_cycle_time, domain_id, cycle_time_us})
  end

  @spec await_running(pos_integer()) :: :ok | {:error, term()}
  def await_running(timeout_ms \\ 10_000), do: safe_call(:await_running, timeout_ms)

  @spec await_operational(pos_integer()) :: :ok | {:error, term()}
  def await_operational(timeout_ms \\ 10_000), do: safe_call(:await_operational, timeout_ms)

  @spec dc_status() :: EtherCAT.DC.Status.t() | {:error, :not_started}
  def dc_status, do: safe_call(:dc_status)

  @spec reference_clock() ::
          {:ok, %{name: atom() | nil, station: non_neg_integer()}} | {:error, term()}
  def reference_clock, do: safe_call(:reference_clock)

  @spec await_dc_locked(pos_integer()) :: :ok | {:error, term()}
  def await_dc_locked(timeout_ms \\ 5_000) do
    case safe_call(:dc_runtime) do
      {:ok, dc_server} -> DCAPI.await_locked(dc_server, timeout_ms)
      {:error, _} = err -> err
    end
  end

  defp safe_call(msg) do
    try do
      :gen_statem.call(EtherCAT.Master, msg)
    catch
      :exit, {:noproc, _} -> {:error, :not_started}
    end
  end

  defp safe_call(msg, timeout) do
    try do
      :gen_statem.call(EtherCAT.Master, msg, timeout)
    catch
      :exit, {:noproc, _} -> {:error, :not_started}
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end
end
