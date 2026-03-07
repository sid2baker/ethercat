defmodule EtherCAT.Domain do
  @moduledoc """
  Self-timed cyclic process image exchange for EtherCAT slaves.

  A Domain owns one flat LRW frame shared across all registered slaves.
  Slaves register their PDOs via `register_pdo/4`, which assigns the logical
  offset immediately and returns it. The slave can then write its FMMU without
  any further coordination. Once all slaves are configured, `start_cycling/1`
  arms the self-timed LRW cycle.

  ## I/O hot path (direct ETS, no gen_statem hop)

      Domain.write(:fast, {:valve, :outputs}, <<0xFF, 0xFF>>)
      {:ok, raw} = Domain.read(:fast, {:sensor, :channels})

  ## Input change notifications

  The Domain sends `{:domain_input, domain_id, key, old_raw_binary | :unset, new_raw_binary}`
  to the registered slave pid whenever an input value changes after a cycle.
  Slaves decode and re-publish to application subscribers.

  ## ETS table schema

      table  : domain_id  (:named_table, :public, :set)
      record : {key, value, slave_pid}
               key        — {slave_name, pdo_name}
               value      — binary | :unset  (:unset until first input cycle completes)
               slave_pid  — pid for inputs, nil for outputs
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Domain.Layout
  alias EtherCAT.Telemetry

  @type domain_id :: atom()
  @type pdo_key :: {slave_name :: atom(), pdo_name :: atom()}

  defstruct [
    :id,
    :bus,
    :period_us,
    :logical_base,
    :next_cycle_at,
    layout: Layout.new(),
    cycle_plan: nil,
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
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5000
    }
  end

  @doc """
  Start a Domain.

  Options:
    - `:id` (required) — atom, also ETS table name and Registry key
    - `:bus` (required) — bus pid
    - `:cycle_time_us` (required) — cycle period in microseconds
    - `:logical_base` — LRW logical address base, default `0`
    - `:miss_threshold` — stop after N consecutive misses, default `100`
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @doc """
  Register a PDO slice. Returns `{:ok, logical_address}` immediately.

  `logical_address` is the **absolute** logical bus address for the FMMU:
  `domain.logical_base + relative_offset_within_image`. The slave must use
  this value directly as the FMMU logical start address.

  Called by Slave in its `:preop` enter handler. The returned address is
  used to write the FMMU register in the same enter callback — no async
  coordination required.

  Direction:
    - `:input`  — slave reads from bus; domain tracks the slave pid for change notifications
    - `:output` — slave writes to bus; no pid tracking
  """
  @spec register_pdo(domain_id(), pdo_key(), pos_integer(), :input | :output) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def register_pdo(domain_id, key, size, direction) do
    slave_pid = if direction == :input, do: self(), else: nil
    safe_call(domain_id, {:register_pdo, key, size, direction, slave_pid})
  end

  @doc """
  Start the self-timed LRW cycle. Call once after all slaves have registered
  their PDOs and written their FMMUs.

  Transitions domain from `:open` to `:cycling`.
  """
  @spec start_cycling(domain_id()) :: :ok | {:error, term()}
  def start_cycling(domain_id) do
    safe_call(domain_id, :start_cycling)
  end

  @doc "Halt cycling. Idempotent in `:open` and `:stopped`; call `start_cycling/1` again to resume."
  @spec stop_cycling(domain_id()) :: :ok | {:error, :not_found}
  def stop_cycling(domain_id) do
    safe_call(domain_id, :stop_cycling)
  end

  @doc "Write raw output bytes. Direct ETS — no gen_statem hop."
  @spec write(domain_id(), pdo_key(), binary()) :: :ok | {:error, :not_found}
  def write(domain_id, key, binary) when is_atom(domain_id) and is_binary(binary) do
    try do
      case :ets.update_element(domain_id, key, {2, binary}) do
        true -> :ok
        false -> {:error, :not_found}
      end
    rescue
      ArgumentError -> {:error, :not_found}
    end
  end

  @doc "Read current raw value (output or input). Direct ETS — no gen_statem hop."
  @spec read(domain_id(), pdo_key()) :: {:ok, binary()} | {:error, :not_found | :not_ready}
  def read(domain_id, key) when is_atom(domain_id) do
    try do
      case stored_value(domain_id, key) do
        {:ok, :unset} -> {:error, :not_ready}
        {:ok, value} -> {:ok, value}
        :error -> {:error, :not_found}
      end
    rescue
      ArgumentError -> {:error, :not_found}
    end
  end

  @doc "Return current stats."
  @spec stats(domain_id()) :: {:ok, map()} | {:error, :not_found}
  def stats(domain_id) do
    safe_call(domain_id, :stats)
  end

  @doc """
  Return a diagnostic snapshot for a domain.

  Returns `{:ok, map}` with keys: `:id`, `:cycle_time_us`, `:state`,
  `:cycle_count`, `:miss_count`, `:total_miss_count`, `:image_size`, `:expected_wkc`.
  """
  @spec info(domain_id()) :: {:ok, map()} | {:error, :not_found}
  def info(domain_id) do
    safe_call(domain_id, :info)
  end

  @doc """
  Update the cycle period for a running domain.

  Takes effect on the next tick. Safe to call in any state.
  """
  @spec update_cycle_time(domain_id(), pos_integer()) :: :ok | {:error, term()}
  def update_cycle_time(domain_id, cycle_time_us)
      when is_integer(cycle_time_us) and cycle_time_us > 0 do
    safe_call(domain_id, {:update_cycle_time, cycle_time_us})
  end

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    bus = Keyword.fetch!(opts, :bus)
    cycle_time_us = Keyword.fetch!(opts, :cycle_time_us)
    logical_base = Keyword.get(opts, :logical_base, 0)
    miss_threshold = Keyword.get(opts, :miss_threshold, 100)

    table =
      :ets.new(id, [
        :set,
        :public,
        :named_table,
        {:write_concurrency, true},
        {:read_concurrency, true}
      ])

    Registry.register(EtherCAT.Registry, {:domain, id}, id)

    data = %__MODULE__{
      id: id,
      bus: bus,
      period_us: cycle_time_us,
      logical_base: logical_base,
      next_cycle_at: nil,
      layout: Layout.new(),
      cycle_plan: nil,
      miss_count: 0,
      miss_threshold: miss_threshold,
      cycle_count: 0,
      total_miss_count: 0,
      table: table
    }

    {:ok, :open, data}
  end

  @impl true
  def handle_event(:enter, _old, :open, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :cycling, data) do
    now = System.monotonic_time(:microsecond)
    delay_us = max(0, data.next_cycle_at - now)
    delay_ms = div(delay_us + 999, 1000)
    {:keep_state_and_data, [{:state_timeout, delay_ms, :tick}]}
  end

  def handle_event(:enter, _old, :stopped, _data), do: :keep_state_and_data

  def handle_event({:call, from}, {:register_pdo, key, size, direction, slave_pid}, :open, data) do
    {offset, layout} = Layout.register(data.layout, key, size, direction, slave_pid)

    ets_value = if direction == :input, do: :unset, else: :binary.copy(<<0>>, size)
    :ets.insert(data.table, {key, ets_value, slave_pid})

    new_data = %{data | layout: layout}

    {:keep_state, new_data, [{:reply, from, {:ok, data.logical_base + offset}}]}
  end

  def handle_event({:call, from}, {:register_pdo, _, _, _, _}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_open}}]}
  end

  def handle_event({:call, from}, :start_cycling, :cycling, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_cycling}}]}
  end

  def handle_event({:call, from}, :start_cycling, state, data) when state in [:open, :stopped],
    do: start_cycling_reply(from, data, reset_miss_count?(state))

  def handle_event({:call, from}, :stop_cycling, state, _data) when state in [:open, :stopped] do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event(:state_timeout, :tick, :cycling, data) do
    t0 = System.monotonic_time(:microsecond)
    image = build_frame(data.cycle_plan.image_size, data.cycle_plan.output_patches, data.table)

    result =
      Bus.transaction(
        data.bus,
        Transaction.lrw({data.logical_base, image}),
        cycle_transaction_timeout_us(data.period_us)
      )

    next_at = data.next_cycle_at + data.period_us

    now_after = System.monotonic_time(:microsecond)
    delay_us = max(0, next_at - now_after)
    delay_ms = div(delay_us + 999, 1000)
    next_timeout = [{:state_timeout, delay_ms, :tick}]

    case result do
      {:ok, [%{data: response, wkc: wkc}]}
      when wkc == data.cycle_plan.expected_wkc and wkc > 0 ->
        dispatch_inputs(response, data.cycle_plan.input_slices, data.table, data.id)
        duration_us = System.monotonic_time(:microsecond) - t0

        Telemetry.domain_cycle_done(data.id, duration_us, data.cycle_count + 1)

        new_data = %{
          data
          | cycle_count: data.cycle_count + 1,
            miss_count: 0,
            next_cycle_at: next_at
        }

        {:keep_state, new_data, next_timeout}

      {:ok, [%{wkc: wkc}]} when wkc >= 0 ->
        reason = {:wkc_mismatch, %{expected: data.cycle_plan.expected_wkc, actual: wkc}}
        mark_cycle_missed(data, reason, next_at, next_timeout)

      {:ok, results} ->
        mark_cycle_missed(data, {:unexpected_reply, length(results)}, next_at, next_timeout)

      {:error, reason} ->
        mark_cycle_missed(data, reason, next_at, next_timeout)
    end
  end

  def handle_event({:call, from}, :stop_cycling, :cycling, data) do
    {:next_state, :stopped, data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :stop_cycling, :stopped, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :stats, state, data) do
    stats = %{
      state: state,
      cycle_count: data.cycle_count,
      miss_count: data.miss_count,
      total_miss_count: data.total_miss_count,
      image_size: Layout.image_size(data.layout),
      expected_wkc: Layout.expected_wkc(data.layout)
    }

    {:keep_state_and_data, [{:reply, from, {:ok, stats}}]}
  end

  def handle_event({:call, from}, :info, state, data) do
    info = %{
      id: data.id,
      cycle_time_us: data.period_us,
      state: state,
      cycle_count: data.cycle_count,
      miss_count: data.miss_count,
      total_miss_count: data.total_miss_count,
      image_size: Layout.image_size(data.layout),
      expected_wkc: Layout.expected_wkc(data.layout)
    }

    {:keep_state_and_data, [{:reply, from, {:ok, info}}]}
  end

  def handle_event({:call, from}, {:update_cycle_time, new_us}, _state, data) do
    {:keep_state, %{data | period_us: new_us}, [{:reply, from, :ok}]}
  end

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  defp build_frame(image_size, output_patches, table) do
    zeros = :binary.copy(<<0>>, image_size)
    iodata = build_iodata(zeros, output_patches, table, 0)
    :erlang.iolist_to_binary(iodata)
  end

  defp build_iodata(frame, [], _table, cursor) do
    [binary_part(frame, cursor, byte_size(frame) - cursor)]
  end

  defp build_iodata(frame, [{offset, size, key} | rest], table, cursor) do
    prefix_len = offset - cursor

    replacement = table |> stored_value(key) |> replacement_value(size)

    [
      binary_part(frame, cursor, prefix_len),
      replacement
      | build_iodata(frame, rest, table, offset + size)
    ]
  end

  defp dispatch_inputs(response, input_slices, table, domain_id) do
    Enum.each(input_slices, fn {offset, size, key, slave_pid} ->
      new_val = binary_part(response, offset, size)
      old_val = stored_value(table, key, nil)

      if new_val != old_val do
        :ets.update_element(table, key, {2, new_val})
        send(slave_pid, {:domain_input, domain_id, key, old_val, new_val})
      end
    end)
  end

  defp binary_pad(data, size) when byte_size(data) >= size, do: binary_part(data, 0, size)
  defp binary_pad(data, size), do: data <> :binary.copy(<<0>>, size - byte_size(data))

  defp start_cycling_reply(from, data, reset_miss_count?) do
    data = if reset_miss_count?, do: %{data | miss_count: 0}, else: data

    case prepare_cycle(data) do
      {:ok, new_data} ->
        {:next_state, :cycling, new_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp reset_miss_count?(:stopped), do: true
  defp reset_miss_count?(:open), do: false

  defp prepare_cycle(data) do
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

  defp stored_value(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value, _}] -> {:ok, value}
      [] -> :error
    end
  end

  defp stored_value(table, key, default) do
    case stored_value(table, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp replacement_value({:ok, value}, size), do: binary_pad(value, size)
  defp replacement_value(:error, size), do: :binary.copy(<<0>>, size)

  defp safe_call(domain_id, msg) do
    try do
      :gen_statem.call(via(domain_id), msg)
    catch
      :exit, {:noproc, _} -> {:error, :not_found}
    end
  end

  defp via(domain_id), do: {:via, Registry, {EtherCAT.Registry, {:domain, domain_id}}}

  defp mark_cycle_missed(data, reason, next_at, next_timeout) do
    Telemetry.domain_cycle_missed(data.id, data.miss_count + 1, reason)

    new_data = %{
      data
      | miss_count: data.miss_count + 1,
        total_miss_count: data.total_miss_count + 1,
        next_cycle_at: next_at
    }

    if new_data.miss_count >= data.miss_threshold do
      Logger.error("[Domain #{data.id}] #{data.miss_threshold} consecutive misses — stopping")
      {:next_state, :stopped, new_data}
    else
      {:keep_state, new_data, next_timeout}
    end
  end

  defp cycle_transaction_timeout_us(period_us)
       when is_integer(period_us) and period_us > 0 do
    max(div(period_us * 9, 10), 200)
  end
end
