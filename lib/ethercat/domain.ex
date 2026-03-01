defmodule EtherCAT.Domain.Config do
  @moduledoc """
  Declarative configuration struct for a Domain.

  Fields:
    - `:id` (required) — atom identifying the domain; also used as the ETS table name
    - `:period` (required) — cycle period in milliseconds
    - `:miss_threshold` — consecutive miss count before domain halts, default `1000`
    - `:logical_base` — LRW logical address base, default `0`
  """
  @enforce_keys [:id, :period]
  defstruct [
    :id,
    :period,
    miss_threshold: 1000,
    logical_base: 0
  ]
end

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

  The Domain sends `{:domain_input, domain_id, key, raw_binary}` to the
  registered slave pid whenever an input value changes after a cycle.
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

  @type domain_id :: atom()
  @type pdo_key :: {slave_name :: atom(), pdo_name :: atom()}

  defstruct [
    :id,
    :link,
    :period_us,
    :logical_base,
    :next_cycle_at,
    # total frame size — grows as PDOs are registered
    image_size: 0,
    # [{offset, size, key}] in registration order
    output_patches: [],
    # [{offset, size, key, slave_pid}] in registration order
    input_slices: [],
    miss_count: 0,
    miss_threshold: 100,
    cycle_count: 0,
    # total accumulated misses since domain started (never resets)
    total_miss_count: 0,
    table: nil
  ]

  # -- child_spec / start_link -----------------------------------------------

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
    - `:link` (required) — Link pid
    - `:period` (required) — cycle period in milliseconds
    - `:logical_base` — LRW logical address base, default `0`
    - `:miss_threshold` — stop after N consecutive misses, default `100`
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  # -- Public API ------------------------------------------------------------

  @doc """
  Register a PDO slice. Returns `{:ok, logical_offset}` immediately.

  Called by Slave in its `:preop` enter handler. The returned offset is
  used to write the FMMU register in the same enter callback — no async
  coordination required.

  Direction:
    - `:input`  — slave reads from bus; domain tracks the slave pid for change notifications
    - `:output` — slave writes to bus; no pid tracking
  """
  @spec register_pdo(domain_id(), pdo_key(), pos_integer(), :input | :output) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def register_pdo(domain_id, key, size, direction) do
    via = {:via, Registry, {EtherCAT.Registry, {:domain, domain_id}}}
    slave_pid = if direction == :input, do: self(), else: nil
    :gen_statem.call(via, {:register_pdo, key, size, direction, slave_pid})
  end

  @doc """
  Start the self-timed LRW cycle. Call once after all slaves have registered
  their PDOs and written their FMMUs.

  Transitions domain from `:open` to `:cycling`.
  """
  @spec start_cycling(domain_id()) :: :ok | {:error, term()}
  def start_cycling(domain_id) do
    via = {:via, Registry, {EtherCAT.Registry, {:domain, domain_id}}}
    :gen_statem.call(via, :start_cycling)
  end

  @doc "Halt cycling. Domain stays alive; call `start_cycling/1` again to resume."
  @spec stop_cyclic(domain_id()) :: :ok
  def stop_cyclic(domain_id) do
    via = {:via, Registry, {EtherCAT.Registry, {:domain, domain_id}}}
    :gen_statem.call(via, :stop_cyclic)
  end

  @doc "Write raw output bytes. Direct ETS — no gen_statem hop."
  @spec write(domain_id(), pdo_key(), binary()) :: :ok | {:error, :not_found}
  def write(domain_id, key, binary) when is_atom(domain_id) and is_binary(binary) do
    case :ets.update_element(domain_id, key, {2, binary}) do
      true -> :ok
      false -> {:error, :not_found}
    end
  end

  @doc "Read current raw value (output or input). Direct ETS — no gen_statem hop."
  @spec read(domain_id(), pdo_key()) :: {:ok, binary()} | {:error, :not_found | :not_ready}
  def read(domain_id, key) when is_atom(domain_id) do
    case :ets.lookup(domain_id, key) do
      [{^key, :unset, _}] -> {:error, :not_ready}
      [{^key, value, _}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @doc "Return current stats."
  @spec stats(domain_id()) :: {:ok, map()}
  def stats(domain_id) do
    via = {:via, Registry, {EtherCAT.Registry, {:domain, domain_id}}}
    :gen_statem.call(via, :stats)
  end

  # -- :gen_statem callbacks -------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    link = Keyword.fetch!(opts, :link)
    period_ms = Keyword.fetch!(opts, :period)
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
      link: link,
      period_us: period_ms * 1000,
      logical_base: logical_base,
      next_cycle_at: nil,
      image_size: 0,
      output_patches: [],
      input_slices: [],
      miss_count: 0,
      miss_threshold: miss_threshold,
      cycle_count: 0,
      total_miss_count: 0,
      table: table
    }

    {:ok, :open, data}
  end

  # -- State enter -----------------------------------------------------------

  @impl true
  def handle_event(:enter, _old, :open, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :cycling, data) do
    now = System.monotonic_time(:microsecond)
    delay_us = max(0, data.next_cycle_at - now)
    delay_ms = div(delay_us + 999, 1000)
    {:keep_state_and_data, [{:state_timeout, delay_ms, :tick}]}
  end

  def handle_event(:enter, _old, :stopped, _data), do: :keep_state_and_data

  # -- :open handlers --------------------------------------------------------

  def handle_event({:call, from}, {:register_pdo, key, size, direction, slave_pid}, :open, data) do
    offset = data.image_size

    ets_value = if direction == :input, do: :unset, else: :binary.copy(<<0>>, size)
    :ets.insert(data.table, {key, ets_value, slave_pid})

    new_data =
      case direction do
        :output ->
          %{
            data
            | image_size: offset + size,
              output_patches: data.output_patches ++ [{offset, size, key}]
          }

        :input ->
          %{
            data
            | image_size: offset + size,
              input_slices: data.input_slices ++ [{offset, size, key, slave_pid}]
          }
      end

    {:keep_state, new_data, [{:reply, from, {:ok, offset}}]}
  end

  def handle_event({:call, from}, {:register_pdo, _, _, _, _}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_open}}]}
  end

  def handle_event({:call, from}, :start_cycling, :open, data) do
    if data.image_size == 0 do
      {:keep_state_and_data, [{:reply, from, {:error, :nothing_registered}}]}
    else
      now = System.monotonic_time(:microsecond)
      new_data = %{data | next_cycle_at: now + data.period_us}
      {:next_state, :cycling, new_data, [{:reply, from, :ok}]}
    end
  end

  def handle_event({:call, from}, :start_cycling, :cycling, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_cycling}}]}
  end

  def handle_event({:call, from}, :start_cycling, :stopped, data) do
    now = System.monotonic_time(:microsecond)
    new_data = %{data | next_cycle_at: now + data.period_us, miss_count: 0}
    {:next_state, :cycling, new_data, [{:reply, from, :ok}]}
  end

  # -- :cycling — self-timed LRW exchange ------------------------------------

  def handle_event(:state_timeout, :tick, :cycling, data) do
    t0 = System.monotonic_time(:microsecond)
    image = build_frame(data.image_size, data.output_patches, data.table)

    result = Bus.transaction(data.link, &Transaction.lrw(&1, {data.logical_base, image}))
    next_at = data.next_cycle_at + data.period_us

    now_after = System.monotonic_time(:microsecond)
    delay_us = max(0, next_at - now_after)
    delay_ms = div(delay_us + 999, 1000)
    next_timeout = [{:state_timeout, delay_ms, :tick}]

    case result do
      {:ok, [%{data: response, wkc: wkc}]} when wkc > 0 ->
        dispatch_inputs(response, data.input_slices, data.table, data.id)
        duration_us = System.monotonic_time(:microsecond) - t0

        :telemetry.execute(
          [:ethercat, :domain, :cycle, :done],
          %{duration_us: duration_us, cycle_count: data.cycle_count + 1},
          %{domain: data.id}
        )

        new_data = %{
          data
          | cycle_count: data.cycle_count + 1,
            miss_count: 0,
            next_cycle_at: next_at
        }

        {:keep_state, new_data, next_timeout}

      other ->
        reason = if match?({:ok, _}, other), do: :no_response, else: elem(other, 1)

        :telemetry.execute(
          [:ethercat, :domain, :cycle, :missed],
          %{miss_count: data.miss_count + 1},
          %{domain: data.id, reason: reason}
        )

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
  end

  def handle_event({:call, from}, :stop_cyclic, :cycling, data) do
    {:next_state, :stopped, data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :stop_cyclic, :stopped, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :stats, state, data) do
    stats = %{
      state: state,
      cycle_count: data.cycle_count,
      miss_count: data.miss_count,
      total_miss_count: data.total_miss_count,
      image_size: data.image_size
    }

    {:keep_state_and_data, [{:reply, from, {:ok, stats}}]}
  end

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # -- Frame assembly --------------------------------------------------------

  # Build the LRW frame using iodata: splice output values from ETS into a
  # zero-filled frame without allocating an intermediate flat binary.
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

    replacement =
      case :ets.lookup(table, key) do
        [{^key, value, _}] -> binary_pad(value, size)
        [] -> :binary.copy(<<0>>, size)
      end

    [
      binary_part(frame, cursor, prefix_len),
      replacement
      | build_iodata(frame, rest, table, offset + size)
    ]
  end

  # Extract inputs from LRW response, compare with stored, notify slave on change.
  defp dispatch_inputs(response, input_slices, table, domain_id) do
    Enum.each(input_slices, fn {offset, size, key, slave_pid} ->
      new_val = binary_part(response, offset, size)

      old_val =
        case :ets.lookup(table, key) do
          [{^key, v, _}] -> v
          [] -> nil
        end

      if new_val != old_val do
        :ets.update_element(table, key, {2, new_val})
        send(slave_pid, {:domain_input, domain_id, key, new_val})
      end
    end)
  end

  defp binary_pad(data, size) when byte_size(data) >= size, do: binary_part(data, 0, size)
  defp binary_pad(data, size), do: data <> :binary.copy(<<0>>, size - byte_size(data))
end
