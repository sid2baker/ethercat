defmodule EtherCAT.Domain.Cycle do
  @moduledoc false

  require Logger

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Domain
  alias EtherCAT.Domain.Freshness
  alias EtherCAT.Domain.Image
  alias EtherCAT.Domain.Layout
  alias EtherCAT.Telemetry
  alias EtherCAT.Utils

  @spec enter_actions(%Domain{}) :: list()
  def enter_actions(data) do
    now = System.monotonic_time(:microsecond)
    delay_us = max(0, data.next_cycle_at - now)
    delay_ms = div(delay_us + 999, 1000)
    [{:state_timeout, delay_ms, :tick}]
  end

  @spec start_reply(term(), %Domain{}, boolean()) :: :gen_statem.event_handler_result(atom())
  def start_reply(from, data, reset_miss_count?) do
    data = if reset_miss_count?, do: %{data | miss_count: 0}, else: data

    case prepare(data) do
      {:ok, new_data} ->
        {:next_state, :cycling, new_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  @spec handle_tick(%Domain{}) :: :gen_statem.event_handler_result(atom())
  def handle_tick(data) do
    t0 = System.monotonic_time(:microsecond)
    cycle_index = data.cycle_count + 1

    image =
      Image.build_frame(data.cycle_plan.image_size, data.cycle_plan.output_patches, data.table)

    result =
      Bus.transaction(
        data.bus,
        Transaction.lrw({data.logical_base, image}),
        cycle_transaction_timeout_us(data)
      )

    next_at = data.next_cycle_at + data.period_us
    next_timeout = next_timeout(next_at)

    case classify_cycle_result(result, data.cycle_plan.expected_wkc) do
      {:valid, response} ->
        handle_valid_cycle(data, response, t0, cycle_index, next_at, next_timeout)

      {:invalid_response, reason} ->
        handle_invalid_cycle_response(data, reason, t0, next_at, next_timeout)

      {:transport_miss, reason} ->
        handle_consecutive_cycle_miss(data, reason, next_at, next_timeout)
    end
  end

  defp handle_valid_cycle(data, response, t0, cycle_index, next_at, next_timeout) do
    maybe_notify_cycle_recovered(data)
    completed_at_us = System.monotonic_time(:microsecond)
    Image.put_domain_status(data.table, completed_at_us, effective_stale_after_us(data))

    dispatch_inputs(
      response,
      data.cycle_plan.input_slices,
      data.table,
      data.id,
      cycle_index,
      completed_at_us
    )

    duration_us = System.monotonic_time(:microsecond) - t0

    Telemetry.domain_cycle_done(data.id, duration_us, cycle_index, completed_at_us)

    new_data = %{
      data
      | cycle_count: cycle_index,
        miss_count: 0,
        cycle_health: :healthy,
        last_cycle_started_at_us: t0,
        last_cycle_completed_at_us: completed_at_us,
        last_valid_cycle_at_us: completed_at_us,
        next_cycle_at: next_at,
        invalid_streak_count: 0,
        degraded?: false
    }

    {:keep_state, new_data, next_timeout}
  end

  # A wrong WKC means the cyclic path is still alive, so it does not count
  # toward the consecutive transport miss threshold that stops the domain.
  defp handle_invalid_cycle_response(data, reason, t0, next_at, next_timeout) do
    new_data =
      record_cycle_fault(data, :invalid, reason, next_at,
        consecutive_miss_count: 0,
        last_cycle_started_at_us: t0
      )

    {:keep_state, new_data, next_timeout}
  end

  defp next_timeout(next_at) do
    now_after = System.monotonic_time(:microsecond)
    delay_us = max(0, next_at - now_after)
    delay_ms = div(delay_us + 999, 1000)
    [{:state_timeout, delay_ms, :tick}]
  end

  defp dispatch_inputs(response, input_slices, table, domain_id, cycle_index, updated_at_us) do
    # Group changes by slave_name to prevent fan-out message flooding
    changes_by_slave =
      Enum.reduce(input_slices, %{}, fn {offset, size, {slave_name, _} = key}, acc ->
        new_val = binary_part(response, offset, size)
        old_val = Image.stored_value(table, key, nil)

        if new_val != old_val do
          Image.update_input(table, key, new_val, updated_at_us)
          change = {key, old_val, new_val}
          Map.update(acc, slave_name, [change], &[change | &1])
        else
          acc
        end
      end)

    Enum.each(changes_by_slave, fn {slave_name, changes} ->
      maybe_dispatch_input(
        slave_name,
        {:domain_inputs, domain_id, cycle_index, changes, updated_at_us}
      )
    end)
  end

  defp maybe_dispatch_input(slave_name, msg) do
    case Registry.lookup(EtherCAT.Registry, {:slave, slave_name}) do
      [{pid, _}] ->
        send(pid, msg)

      [] ->
        :ok
    end
  end

  defp prepare(data) do
    case Layout.prepare(data.layout) do
      {:ok, cycle_plan} ->
        now = System.monotonic_time(:microsecond)

        {:ok,
         %{
           data
           | cycle_plan: cycle_plan,
             next_cycle_at: now + data.period_us
         }}

      {:error, _} = err ->
        err
    end
  end

  # Bus errors and unusable replies count as consecutive transport misses and
  # drive the miss threshold that stops the domain.
  #
  # Domain health keeps timeout-class misses stable as `:timeout` even when the
  # underlying realtime bus submission expires in the queue. The bus still
  # exposes `:expired` through its own telemetry, but cyclic domain health is
  # about whether the cycle missed its transport window, not which scheduler
  # edge produced that miss.
  defp handle_consecutive_cycle_miss(data, reason, next_at, next_timeout) do
    new_data =
      record_cycle_fault(data, :transport_miss, reason, next_at,
        consecutive_miss_count: data.miss_count + 1
      )

    if stop_domain_now?(reason, new_data.miss_count, data.miss_threshold) do
      log_domain_stop(data.id, reason, data.miss_threshold)
      Telemetry.domain_stopped(data.id, reason)
      send(EtherCAT.Master, {:domain_stopped, data.id, reason})
      {:next_state, :stopped, new_data}
    else
      {:keep_state, new_data, next_timeout}
    end
  end

  defp record_cycle_fault(data, category, reason, next_at, opts) do
    invalid_at_us = System.monotonic_time(:microsecond)
    next_miss_count = Keyword.fetch!(opts, :consecutive_miss_count)
    next_total_miss_count = data.total_miss_count + 1
    next_invalid_streak_count = next_invalid_streak_count(data, category)
    next_degraded? = next_degraded?(data, reason, next_invalid_streak_count)

    emit_cycle_fault_telemetry(
      category,
      data.id,
      next_miss_count,
      next_total_miss_count,
      reason,
      invalid_at_us
    )

    maybe_notify_cycle_degraded(data, reason, next_invalid_streak_count, next_degraded?)

    data
    |> Map.put(:miss_count, next_miss_count)
    |> Map.put(:cycle_health, {:invalid, reason})
    |> Map.put(:last_invalid_cycle_at_us, invalid_at_us)
    |> Map.put(:last_invalid_reason, reason)
    |> Map.put(:total_miss_count, next_total_miss_count)
    |> Map.put(:next_cycle_at, next_at)
    |> Map.put(:invalid_streak_count, next_invalid_streak_count)
    |> Map.put(:degraded?, next_degraded?)
    |> maybe_put_last_cycle_started_at(opts)
  end

  defp emit_cycle_fault_telemetry(
         :invalid,
         domain_id,
         _next_miss_count,
         next_total_miss_count,
         reason,
         invalid_at_us
       ) do
    Telemetry.domain_cycle_invalid(domain_id, next_total_miss_count, reason, invalid_at_us)
  end

  defp emit_cycle_fault_telemetry(
         :transport_miss,
         domain_id,
         next_miss_count,
         next_total_miss_count,
         reason,
         invalid_at_us
       ) do
    Telemetry.domain_cycle_transport_miss(
      domain_id,
      next_miss_count,
      next_total_miss_count,
      reason,
      invalid_at_us
    )
  end

  defp maybe_put_last_cycle_started_at(data, opts) do
    case Keyword.fetch(opts, :last_cycle_started_at_us) do
      {:ok, t0} -> %{data | last_cycle_started_at_us: t0}
      :error -> data
    end
  end

  defp cycle_transaction_timeout_us(%{period_us: period_us, frame_timeout_ms: frame_timeout_ms})
       when is_integer(period_us) and period_us > 0 do
    base_timeout_us = max(div(period_us * 9, 10), 200)

    frame_budget_timeout_us =
      case frame_timeout_ms do
        timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
          timeout_ms * 1_000 + 1_000

        _other ->
          0
      end

    max(base_timeout_us, frame_budget_timeout_us)
  end

  defp effective_stale_after_us(%{stale_after_us: stale_after_us})
       when is_integer(stale_after_us) and stale_after_us > 0 do
    stale_after_us
  end

  defp effective_stale_after_us(%{period_us: period_us}) do
    Freshness.default_stale_after_us(period_us)
  end

  defp classify_cycle_result({:ok, [%{data: response, wkc: wkc}]}, expected_wkc)
       when wkc == expected_wkc and wkc > 0 do
    {:valid, response}
  end

  defp classify_cycle_result({:ok, [%{wkc: wkc}]}, expected_wkc) when wkc >= 0 do
    {:invalid_response, {:wkc_mismatch, %{expected: expected_wkc, actual: wkc}}}
  end

  defp classify_cycle_result({:ok, results}, _expected_wkc) do
    {:transport_miss, {:unexpected_reply, length(results)}}
  end

  defp classify_cycle_result({:error, reason}, _expected_wkc) do
    {:transport_miss, normalize_transport_miss_reason(reason)}
  end

  defp normalize_transport_miss_reason(:expired), do: :timeout
  defp normalize_transport_miss_reason(reason), do: reason

  defp maybe_notify_cycle_degraded(
         %{degraded?: false, id: id},
         reason,
         invalid_streak_count,
         true
       ) do
    send(EtherCAT.Master, {:domain_cycle_degraded, id, reason, invalid_streak_count})
  end

  defp maybe_notify_cycle_degraded(_data, _reason, _invalid_streak_count, _next_degraded?),
    do: :ok

  defp maybe_notify_cycle_recovered(%{degraded?: true, id: id}) do
    send(EtherCAT.Master, {:domain_cycle_recovered, id})
  end

  defp maybe_notify_cycle_recovered(_data), do: :ok

  defp next_invalid_streak_count(%{invalid_streak_count: streak_count}, _category)
       when is_integer(streak_count) and streak_count >= 0 do
    streak_count + 1
  end

  defp next_invalid_streak_count(_data, _category), do: 1

  defp next_degraded?(%{degraded?: degraded?}, _reason, _invalid_streak_count) when degraded?,
    do: true

  defp next_degraded?(%{recovery_threshold: recovery_threshold}, _reason, invalid_streak_count)
       when is_integer(recovery_threshold) and recovery_threshold > 0 do
    invalid_streak_count >= recovery_threshold
  end

  defp next_degraded?(_data, _reason, _invalid_streak_count), do: false

  defp stop_domain_now?(:down, _miss_count, _miss_threshold), do: true
  defp stop_domain_now?(_reason, miss_count, miss_threshold), do: miss_count >= miss_threshold

  defp log_domain_stop(id, :down, _miss_threshold) do
    Logger.error(
      "[Domain #{id}] confirmed bus down — stopping",
      component: :domain,
      domain: id,
      event: :stopped,
      reason_kind: :down
    )
  end

  defp log_domain_stop(id, reason, miss_threshold) do
    Logger.error(
      "[Domain #{id}] #{miss_threshold} consecutive misses — stopping",
      component: :domain,
      domain: id,
      event: :stopped,
      reason_kind: Utils.reason_kind(reason),
      miss_threshold: miss_threshold
    )
  end
end
