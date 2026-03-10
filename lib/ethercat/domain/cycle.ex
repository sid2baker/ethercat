defmodule EtherCAT.Domain.Cycle do
  @moduledoc false

  require Logger

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Domain
  alias EtherCAT.Domain.Image
  alias EtherCAT.Domain.Layout
  alias EtherCAT.Telemetry

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
        cycle_transaction_timeout_us(data.period_us)
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

    dispatch_inputs(response, data.cycle_plan.input_slices, data.table, data.id, completed_at_us)

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
        next_cycle_at: next_at
    }

    {:keep_state, new_data, next_timeout}
  end

  # A wrong WKC means the cyclic path is still alive, so it does not count
  # toward the consecutive transport miss threshold that stops the domain.
  defp handle_invalid_cycle_response(data, reason, t0, next_at, next_timeout) do
    new_data =
      record_cycle_fault(data, reason, next_at,
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

  defp dispatch_inputs(response, input_slices, table, domain_id, updated_at_us) do
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
      maybe_dispatch_input(slave_name, {:domain_inputs, domain_id, changes})
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
  defp handle_consecutive_cycle_miss(data, reason, next_at, next_timeout) do
    new_data =
      record_cycle_fault(data, reason, next_at, consecutive_miss_count: data.miss_count + 1)

    if stop_domain_now?(reason, new_data.miss_count, data.miss_threshold) do
      log_domain_stop(data.id, reason, data.miss_threshold)
      Telemetry.domain_stopped(data.id, reason)
      send(EtherCAT.Master, {:domain_stopped, data.id, reason})
      {:next_state, :stopped, new_data}
    else
      {:keep_state, new_data, next_timeout}
    end
  end

  defp record_cycle_fault(data, reason, next_at, opts) do
    invalid_at_us = System.monotonic_time(:microsecond)
    next_miss_count = Keyword.fetch!(opts, :consecutive_miss_count)
    next_total_miss_count = data.total_miss_count + 1

    # Historical telemetry name: this event covers invalid cycle responses as
    # well as transport misses, not only stop-threshold misses.
    Telemetry.domain_cycle_missed(
      data.id,
      next_miss_count,
      next_total_miss_count,
      reason,
      invalid_at_us
    )

    maybe_notify_cycle_invalid(data, reason)

    data
    |> Map.put(:miss_count, next_miss_count)
    |> Map.put(:cycle_health, {:invalid, reason})
    |> Map.put(:last_invalid_cycle_at_us, invalid_at_us)
    |> Map.put(:last_invalid_reason, reason)
    |> Map.put(:total_miss_count, next_total_miss_count)
    |> Map.put(:next_cycle_at, next_at)
    |> maybe_put_last_cycle_started_at(opts)
  end

  defp maybe_put_last_cycle_started_at(data, opts) do
    case Keyword.fetch(opts, :last_cycle_started_at_us) do
      {:ok, t0} -> %{data | last_cycle_started_at_us: t0}
      :error -> data
    end
  end

  defp cycle_transaction_timeout_us(period_us) when is_integer(period_us) and period_us > 0 do
    max(div(period_us * 9, 10), 200)
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
    {:transport_miss, reason}
  end

  defp maybe_notify_cycle_invalid(%{cycle_health: :healthy, id: id}, reason) do
    send(EtherCAT.Master, {:domain_cycle_invalid, id, reason})
  end

  defp maybe_notify_cycle_invalid(_data, _reason), do: :ok

  defp maybe_notify_cycle_recovered(%{cycle_health: {:invalid, _reason}, id: id}) do
    send(EtherCAT.Master, {:domain_cycle_recovered, id})
  end

  defp maybe_notify_cycle_recovered(_data), do: :ok

  defp stop_domain_now?(:down, _miss_count, _miss_threshold), do: true
  defp stop_domain_now?(_reason, miss_count, miss_threshold), do: miss_count >= miss_threshold

  defp log_domain_stop(id, :down, _miss_threshold) do
    Logger.error("[Domain #{id}] confirmed bus down — stopping")
  end

  defp log_domain_stop(id, _reason, miss_threshold) do
    Logger.error("[Domain #{id}] #{miss_threshold} consecutive misses — stopping")
  end
end
