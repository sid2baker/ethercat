defmodule EtherCAT.Master.API do
  @moduledoc """
  Low-level synchronous facade for the local `EtherCAT.Master` process.

  This module is intentionally thin. It keeps public call wrappers out of
  `EtherCAT.Master` so the state machine file can stay focused on session states
  and transitions.
  """

  alias EtherCAT.Bus
  alias EtherCAT.DC.API, as: DCAPI
  alias EtherCAT.Utils

  @call_timeout_ms 5_000
  # Wait-style calls are satisfied by later state transitions. Give the local
  # call a small grace window so near-boundary replies do not surface as a
  # caller timeout instead of the terminal runtime result.
  @wait_call_grace_floor_ms 10
  @wait_call_grace_cap_ms 100

  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: safe_call({:start, opts})

  @spec stop() :: :ok | :already_stopped | {:error, :timeout | {:server_exit, term()}}
  def stop do
    try do
      :gen_statem.call(EtherCAT.Master, :stop)
    catch
      :exit, reason ->
        case Utils.classify_call_exit(reason, :already_stopped) do
          {:error, :already_stopped} -> :already_stopped
          {:error, _} = err -> err
        end
    end
  end

  @spec slaves() :: list() | {:error, :not_started | :timeout | {:server_exit, term()}}
  def slaves, do: safe_call(:slaves)

  @spec domains() :: list() | {:error, :not_started | :timeout | {:server_exit, term()}}
  def domains, do: safe_call(:domains)

  @spec bus() :: Bus.server() | nil | {:error, :not_started | :timeout | {:server_exit, term()}}
  def bus, do: safe_call(:bus)

  @spec last_failure() :: map() | nil | {:error, :not_started | :timeout | {:server_exit, term()}}
  def last_failure, do: safe_call(:last_failure)

  @spec state() :: atom() | {:error, :not_started | :timeout | {:server_exit, term()}}
  def state, do: safe_call(:state)

  @spec configure_slave(atom(), keyword() | EtherCAT.Slave.Config.t()) :: :ok | {:error, term()}
  def configure_slave(slave_name, spec) do
    safe_call({:configure_slave, slave_name, spec})
  end

  @spec activate() :: :ok | {:error, term()}
  def activate, do: safe_call(:activate)

  @spec deactivate(:safeop | :preop) :: :ok | {:error, term()}
  def deactivate(target \\ :safeop)

  def deactivate(target) when target in [:safeop, :preop] do
    safe_call({:deactivate, target})
  end

  def deactivate(_target), do: {:error, :invalid_deactivate_target}

  @spec update_domain_cycle_time(atom(), pos_integer()) :: :ok | {:error, term()}
  def update_domain_cycle_time(domain_id, cycle_time_us)
      when is_atom(domain_id) and is_integer(cycle_time_us) and cycle_time_us > 0 do
    safe_call({:update_domain_cycle_time, domain_id, cycle_time_us})
  end

  @spec await_running(pos_integer()) :: :ok | {:error, term()}
  def await_running(timeout_ms \\ 10_000), do: safe_wait_call(:await_running, timeout_ms)

  @spec await_operational(pos_integer()) :: :ok | {:error, term()}
  def await_operational(timeout_ms \\ 10_000),
    do: safe_wait_call(:await_operational, timeout_ms)

  @spec dc_status() ::
          EtherCAT.DC.Status.t() | {:error, :not_started | :timeout | {:server_exit, term()}}
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
      :gen_statem.call(EtherCAT.Master, msg, @call_timeout_ms)
    catch
      :exit, reason -> Utils.classify_call_exit(reason, :not_started)
    end
  end

  defp safe_call(msg, timeout) do
    try do
      :gen_statem.call(EtherCAT.Master, msg, timeout)
    catch
      :exit, reason -> Utils.classify_call_exit(reason, :not_started)
    end
  end

  defp safe_wait_call(msg, timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    safe_call(msg, timeout_ms + wait_call_grace_ms(timeout_ms))
  end

  defp wait_call_grace_ms(timeout_ms) do
    timeout_ms
    |> div(20)
    |> max(@wait_call_grace_floor_ms)
    |> min(@wait_call_grace_cap_ms)
  end
end
