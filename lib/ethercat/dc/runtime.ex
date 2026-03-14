defmodule EtherCAT.DC.Runtime do
  @moduledoc false

  require Logger

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.DC
  alias EtherCAT.DC.Status
  alias EtherCAT.Slave.ESC.Registers
  alias EtherCAT.Telemetry
  alias EtherCAT.Utils

  @default_diagnostic_interval_ns 10_000_000

  @spec enter_actions(%DC{}) :: [{:state_timeout, pos_integer(), :tick}]
  def enter_actions(data), do: [{:state_timeout, data.tick_interval_ms, :tick}]

  @spec status_reply(term(), %DC{}) :: :gen_statem.event_handler_result(atom())
  def status_reply(from, data) do
    {:keep_state_and_data, [{:reply, from, runtime_status(data)}]}
  end

  @spec handle_tick(%DC{}) :: :gen_statem.event_handler_result(atom())
  def handle_tick(data) do
    request = build_runtime_request(data)

    updated_data =
      case Bus.transaction(data.bus, request.tx, tick_timeout_us(data.config.cycle_ns)) do
        {:ok, replies} ->
          process_runtime_replies(data, request, replies)

        {:error, reason} ->
          process_runtime_failure(data, %{diagnostics?: request.diagnostics?}, reason)
      end

    {:keep_state, %{updated_data | cycle_count: data.cycle_count + 1}, enter_actions(data)}
  end

  @spec await_locked(DC.server(), pos_integer(), (DC.server() -> Status.t() | {:error, term()})) ::
          :ok | {:error, term()}
  def await_locked(server, timeout_ms, status_fun)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_await_locked(server, deadline_ms, status_fun)
  end

  @spec maintenance_transaction(non_neg_integer()) :: Transaction.t()
  def maintenance_transaction(ref_station) when is_integer(ref_station) and ref_station >= 0 do
    Transaction.frmw(ref_station, Registers.dc_system_time())
  end

  @spec decode_abs_sync_diff(non_neg_integer()) :: non_neg_integer()
  def decode_abs_sync_diff(raw) when is_integer(raw) and raw >= 0 do
    <<_::1, abs_sync_diff_ns::31>> = <<raw::32>>
    abs_sync_diff_ns
  end

  @spec classify_lock([non_neg_integer()], pos_integer()) ::
          {:locking | :locked | :unavailable, non_neg_integer() | nil}
  def classify_lock([], _threshold_ns), do: {:unavailable, nil}

  def classify_lock(sync_diffs, threshold_ns)
      when is_list(sync_diffs) and is_integer(threshold_ns) and threshold_ns > 0 do
    max_sync_diff_ns = Enum.max(sync_diffs)

    if max_sync_diff_ns <= threshold_ns do
      {:locked, max_sync_diff_ns}
    else
      {:locking, max_sync_diff_ns}
    end
  end

  @spec initial_lock_state([non_neg_integer()]) :: Status.lock_state()
  def initial_lock_state([]), do: :unavailable
  def initial_lock_state(_stations), do: :locking

  @spec tick_interval_ms(pos_integer()) :: pos_integer()
  def tick_interval_ms(cycle_ns) when is_integer(cycle_ns) and cycle_ns > 0 do
    ceil_div(cycle_ns, 1_000_000)
  end

  @spec diagnostic_interval_cycles(pos_integer()) :: pos_integer()
  def diagnostic_interval_cycles(cycle_ns) when is_integer(cycle_ns) and cycle_ns > 0 do
    max(1, ceil_div(@default_diagnostic_interval_ns, cycle_ns))
  end

  def runtime_status(data) do
    %Status{
      configured?: true,
      active?: true,
      cycle_ns: data.config.cycle_ns,
      await_lock?: data.config.await_lock?,
      lock_policy: data.config.lock_policy,
      reference_station: data.ref_station,
      lock_state: data.lock_state,
      max_sync_diff_ns: data.max_sync_diff_ns,
      last_sync_check_at_ms: data.last_sync_check_at_ms,
      monitor_failures: data.fail_count
    }
  end

  defp build_runtime_request(data) do
    diagnostics? =
      data.monitored_stations != [] and
        rem(data.cycle_count + 1, data.diagnostic_interval_cycles) == 0

    tx =
      data.ref_station
      |> maintenance_transaction()
      |> maybe_append_sync_diff_reads(diagnostics?, data.monitored_stations)

    %{tx: tx, diagnostics?: diagnostics?}
  end

  defp maybe_append_sync_diff_reads(tx, false, _stations), do: tx

  defp maybe_append_sync_diff_reads(tx, true, stations) do
    Enum.reduce(stations, tx, fn station, acc ->
      Transaction.fprd(acc, station, Registers.dc_system_time_diff())
    end)
  end

  defp process_runtime_replies(data, %{diagnostics?: false}, [%{wkc: wkc}]) when wkc > 0 do
    maybe_log_runtime_recovered(data.fail_count)
    maybe_notify_runtime_recovered(data)
    Telemetry.dc_tick(data.ref_station, wkc)
    %{data | fail_count: 0, notify_recovered_on_success?: false}
  end

  defp process_runtime_replies(data, %{diagnostics?: true}, [%{wkc: wkc} | diag_replies])
       when wkc > 0 do
    case decode_sync_diffs(data.monitored_stations, diag_replies, []) do
      {:ok, sync_diffs} ->
        maybe_log_runtime_recovered(data.fail_count)
        maybe_notify_runtime_recovered(data)
        Telemetry.dc_tick(data.ref_station, wkc)

        now_ms = System.system_time(:millisecond)

        {classified_state, max_sync_diff_ns} =
          classify_lock(sync_diffs, data.config.lock_threshold_ns)

        lock_state =
          apply_warmup(classified_state, data.cycle_count + 1, data.config.warmup_cycles)

        updated = %{
          data
          | fail_count: 0,
            lock_state: lock_state,
            max_sync_diff_ns: max_sync_diff_ns,
            last_sync_check_at_ms: now_ms,
            notify_recovered_on_success?: false
        }

        emit_monitor_telemetry(data, updated)
        updated

      {:error, reason} ->
        process_runtime_failure(data, %{diagnostics?: true}, reason)
    end
  end

  defp process_runtime_replies(data, _request, replies) do
    process_runtime_failure(data, %{diagnostics?: false}, {:unexpected_reply, length(replies)})
  end

  defp process_runtime_failure(data, %{diagnostics?: diagnostics?}, reason) do
    failures = data.fail_count + 1

    if failures >= 3 and (failures == 3 or rem(failures, 100) == 0) do
      Logger.warning(
        "[DC] runtime tick failed: #{inspect(reason)} (#{failures} consecutive)",
        component: :dc,
        event: :runtime_tick_failed,
        ref_station: data.ref_station,
        reason_kind: Utils.reason_kind(reason),
        consecutive_failures: failures
      )
    end

    if failures == 3 do
      Telemetry.dc_runtime_state_changed(:healthy, :failing, reason, failures)
      send(EtherCAT.Master, {:dc_runtime_failed, reason})
    end

    updated =
      if diagnostics? and data.monitored_stations != [] do
        now_ms = System.system_time(:millisecond)
        next_state = if data.monitored_stations == [], do: :unavailable, else: :locking

        new_data = %{
          data
          | fail_count: failures,
            lock_state: next_state,
            last_sync_check_at_ms: now_ms
        }

        emit_monitor_telemetry(data, new_data)
        new_data
      else
        %{data | fail_count: failures}
      end

    updated
  end

  defp maybe_log_runtime_recovered(0), do: :ok

  defp maybe_log_runtime_recovered(fail_count) when fail_count >= 3 do
    Telemetry.dc_runtime_state_changed(:failing, :healthy, nil, fail_count)

    Logger.info(
      "[DC] runtime recovered after #{fail_count} failure(s)",
      component: :dc,
      event: :runtime_recovered,
      consecutive_failures: fail_count
    )
  end

  defp maybe_log_runtime_recovered(fail_count) when fail_count > 0 do
    Logger.info(
      "[DC] runtime recovered after #{fail_count} failure(s)",
      component: :dc,
      event: :runtime_recovered,
      consecutive_failures: fail_count
    )
  end

  defp maybe_notify_runtime_recovered(%{notify_recovered_on_success?: true}) do
    send(EtherCAT.Master, {:dc_runtime_recovered})
  end

  defp maybe_notify_runtime_recovered(%{fail_count: fail_count}) when fail_count >= 3 do
    send(EtherCAT.Master, {:dc_runtime_recovered})
  end

  defp maybe_notify_runtime_recovered(_data), do: :ok

  defp emit_monitor_telemetry(old_data, new_data) do
    maybe_emit_sync_diff(new_data)
    maybe_emit_lock_change(old_data, new_data)
  end

  defp maybe_emit_sync_diff(%{
         max_sync_diff_ns: max_sync_diff_ns,
         ref_station: ref_station,
         monitored_stations: monitored_stations
       })
       when is_integer(max_sync_diff_ns) and is_integer(ref_station) do
    Telemetry.dc_sync_diff_observed(ref_station, max_sync_diff_ns, length(monitored_stations))
  end

  defp maybe_emit_sync_diff(_data), do: :ok

  defp maybe_emit_lock_change(%{lock_state: lock_state}, %{lock_state: lock_state}), do: :ok

  defp maybe_emit_lock_change(old_data, %{ref_station: ref_station} = new_data)
       when is_integer(ref_station) do
    Telemetry.dc_lock_changed(
      ref_station,
      old_data.lock_state,
      new_data.lock_state,
      new_data.max_sync_diff_ns
    )

    maybe_notify_lock_change(old_data, new_data)
  end

  defp maybe_emit_lock_change(_old_data, _new_data), do: :ok

  defp maybe_notify_lock_change(%{lock_state: :locked}, %{lock_state: new_state} = new_data)
       when new_state != :locked do
    send(EtherCAT.Master, {:dc_lock_lost, new_state, new_data.max_sync_diff_ns})
  end

  defp maybe_notify_lock_change(%{lock_state: old_state}, %{lock_state: :locked} = new_data)
       when old_state != :locked do
    send(EtherCAT.Master, {:dc_lock_regained, new_data.max_sync_diff_ns})
  end

  defp maybe_notify_lock_change(_old_data, _new_data), do: :ok

  defp decode_sync_diffs([], [], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_sync_diffs(
         [_station | stations],
         [%{data: <<raw::32-little>>, wkc: 1} | results],
         acc
       ) do
    decode_sync_diffs(stations, results, [decode_abs_sync_diff(raw) | acc])
  end

  defp decode_sync_diffs([station | _stations], [%{wkc: wkc} | _results], _acc) do
    {:error, {:sync_diff_read_failed, station, {:unexpected_wkc, wkc}}}
  end

  defp decode_sync_diffs(stations, results, _acc) do
    {:error, {:sync_diff_unexpected_reply_count, length(results), length(stations)}}
  end

  defp apply_warmup(:unavailable, _cycle_number, _warmup_cycles), do: :unavailable

  defp apply_warmup(lock_state, cycle_number, warmup_cycles)
       when is_integer(warmup_cycles) and warmup_cycles > 0 and cycle_number <= warmup_cycles do
    case lock_state do
      :locked -> :locking
      other -> other
    end
  end

  defp apply_warmup(lock_state, _cycle_number, _warmup_cycles), do: lock_state

  defp do_await_locked(server, deadline_ms, status_fun) do
    case status_fun.(server) do
      %Status{lock_state: :locked} ->
        :ok

      %Status{lock_state: :unavailable} ->
        {:error, :dc_lock_unavailable}

      {:error, _reason} = err ->
        err

      %Status{} = status ->
        remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

        if remaining_ms <= 0 do
          {:error, :timeout}
        else
          Process.sleep(min(await_poll_interval_ms(status), remaining_ms))
          do_await_locked(server, deadline_ms, status_fun)
        end
    end
  end

  defp await_poll_interval_ms(%Status{cycle_ns: cycle_ns})
       when is_integer(cycle_ns) and cycle_ns > 0 do
    cycle_ms = max(1, ceil_div(cycle_ns, 1_000_000))
    min(cycle_ms, 10)
  end

  defp await_poll_interval_ms(_status), do: 1

  defp tick_timeout_us(cycle_ns) when is_integer(cycle_ns) and cycle_ns > 0 do
    cycle_us = div(cycle_ns, 1_000)
    max(div(cycle_us * 9, 10), 200)
  end

  defp ceil_div(value, divisor) when is_integer(value) and is_integer(divisor) and divisor > 0 do
    div(value + divisor - 1, divisor)
  end
end
