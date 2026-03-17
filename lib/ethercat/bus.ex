defmodule EtherCAT.Bus do
  @moduledoc """
  Public API for the EtherCAT bus scheduler.

  `EtherCAT.Bus` is the single serialization point for all EtherCAT frame I/O.
  Callers build `EtherCAT.Bus.Transaction` values and submit them as either:

  - `transaction/2` — reliable work, eligible for batching with other reliable transactions
  - `transaction/3` — realtime work with a staleness budget; stale work is discarded

  Realtime and reliable transactions are strictly separated:
  realtime always has priority, and realtime transactions never share a frame with
  reliable transactions.

  In this API, `reliable` means non-expiring background work: the bus keeps it
  queued until it can be sent or the link fails. It does not mean the transport
  can never time out.

  `realtime` means deadline-sensitive work: it gets priority and is dropped
  once it has become too old to be useful.

  The public API is singleton-first: `info/0`, `transaction/1`,
  `set_frame_timeout/1`, `settle/0`, and `quiesce/1` target the registered
  `EtherCAT.Bus` process by default. Explicit server-ref variants remain
  available for internal callers and tests.
  """

  alias EtherCAT.Bus.Link
  alias EtherCAT.Bus.{Result, Transaction}
  alias EtherCAT.{Telemetry, Utils}

  @type server :: :gen_statem.server_ref()
  @type call_error :: {:error, :not_started | :timeout | {:server_exit, term()}}

  @call_timeout_ms 5_000

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5000
    }
  end

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    link_mod = if opts[:backup_interface], do: Link.Redundant, else: Link.Single
    link_mod.start_link(opts)
  end

  @doc """
  Execute a reliable transaction.

  Reliable work may be batched with other reliable transactions when the bus is
  already busy, but an idle bus sends immediately.

  `Reliable` here means non-expiring background work. The bus will not discard
  it due to age while it is queued, but the transaction can still fail due to
  timeouts or link loss.
  """
  @spec transaction(Transaction.t()) :: {:ok, [Result.t()]} | call_error() | {:error, term()}
  def transaction(%Transaction{} = tx), do: transaction(__MODULE__, tx)

  @spec transaction(server(), Transaction.t()) ::
          {:ok, [Result.t()]} | call_error() | {:error, term()}
  def transaction(bus, %Transaction{} = tx) do
    do_call(bus, {:transact, tx, nil, System.monotonic_time(:microsecond)}, tx)
  end

  @doc """
  Execute a realtime transaction with a staleness budget in microseconds.

  Realtime work is discarded if it has become stale by the time the bus is ready
  to dispatch it. Realtime transactions are never mixed with reliable traffic.

  `stale_after_us` is a max queued age relative to submission time, not an
  absolute wall-clock deadline.
  """
  @spec transaction(Transaction.t(), pos_integer()) ::
          {:ok, [Result.t()]} | call_error() | {:error, term()}
  def transaction(%Transaction{} = tx, stale_after_us)
      when is_integer(stale_after_us) and stale_after_us > 0 do
    transaction(__MODULE__, tx, stale_after_us)
  end

  @spec transaction(server(), Transaction.t(), pos_integer()) ::
          {:ok, [Result.t()]} | call_error() | {:error, term()}
  def transaction(bus, %Transaction{} = tx, stale_after_us)
      when is_integer(stale_after_us) and stale_after_us > 0 do
    do_call(bus, {:transact, tx, stale_after_us, System.monotonic_time(:microsecond)}, tx)
  end

  @doc """
  Update the frame response timeout in milliseconds.
  """
  @spec set_frame_timeout(pos_integer()) :: :ok | call_error() | {:error, term()}
  def set_frame_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    set_frame_timeout(__MODULE__, timeout_ms)
  end

  @spec set_frame_timeout(server(), pos_integer()) :: :ok | call_error() | {:error, term()}
  def set_frame_timeout(bus, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    safe_call(bus, {:set_frame_timeout, timeout_ms})
  end

  @doc """
  Return low-level bus runtime information, including queue and in-flight state.
  """
  @spec info() :: {:ok, map()} | call_error()
  def info, do: info(__MODULE__)

  @spec info(server()) :: {:ok, map()} | call_error()
  def info(bus), do: safe_call(bus, :info)

  @doc """
  Wait until the bus is idle, then drain any buffered receive traffic.

  This is useful after startup/configuration phases where callers want the next
  transaction to begin from a quiescent transport state.
  """
  @spec settle() :: :ok | call_error()
  def settle, do: settle(__MODULE__)

  @spec settle(server()) :: :ok | call_error()
  def settle(bus), do: safe_call(bus, :settle)

  @doc """
  Drain the bus, wait through a short quiet window, then drain once more.

  This is useful when late transport traffic can still land just after the bus
  first reports idle, for example after startup/configuration exchanges.
  """
  @spec quiesce(non_neg_integer()) :: :ok | call_error()
  def quiesce(quiet_ms \\ 0)
      when is_integer(quiet_ms) and quiet_ms >= 0 do
    quiesce(__MODULE__, quiet_ms)
  end

  @spec quiesce(server(), non_neg_integer()) :: :ok | call_error()
  def quiesce(bus, quiet_ms)
      when is_integer(quiet_ms) and quiet_ms >= 0 do
    with :ok <- settle(bus),
         :ok <- wait_quiet_window(quiet_ms),
         :ok <- settle(bus) do
      :ok
    end
  end

  defp do_call(bus, msg, tx) do
    datagram_count = tx |> Transaction.datagrams() |> length()
    class = call_class(msg)
    meta = %{datagram_count: datagram_count, class: class}

    Telemetry.span([:ethercat, :bus, :transact], meta, fn ->
      result = safe_call(bus, msg)

      case result do
        {:ok, response_datagrams} ->
          results = Enum.map(response_datagrams, &result_from_datagram/1)

          stop_meta = %{
            datagram_count: datagram_count,
            total_wkc: Enum.sum(Enum.map(results, & &1.wkc)),
            class: class,
            status: :ok,
            error_kind: nil
          }

          {{:ok, results}, stop_meta}

        {:error, reason} = err ->
          stop_meta = %{
            datagram_count: datagram_count,
            total_wkc: 0,
            class: class,
            status: :error,
            error_kind: Utils.reason_kind(reason)
          }

          {err, stop_meta}
      end
    end)
  end

  defp result_from_datagram(dg) do
    %Result{
      data: dg.data,
      wkc: dg.wkc,
      circular: dg.circular,
      irq: <<dg.irq::little-unsigned-16>>
    }
  end

  defp call_class({:transact, _tx, nil, _enqueued_at_us}), do: :reliable
  defp call_class({:transact, _tx, _stale_after_us, _enqueued_at_us}), do: :realtime

  defp wait_quiet_window(0), do: :ok

  defp wait_quiet_window(quiet_ms) do
    Process.sleep(quiet_ms)
    :ok
  end

  defp safe_call(bus, msg, timeout \\ @call_timeout_ms) do
    try do
      :gen_statem.call(bus, msg, timeout)
    catch
      :exit, reason -> Utils.classify_call_exit(reason, :not_started)
    end
  end
end
