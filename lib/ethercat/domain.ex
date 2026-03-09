defmodule EtherCAT.Domain do
  @moduledoc """
  Cyclic process image for one logical EtherCAT domain.

  One Domain per configured domain ID. Slaves register their PDOs during PREOP,
  then the domain runs a self-timed LRW exchange each cycle.

  ## States

  - `:open` — accepting PDO registrations, not yet cycling
  - `:cycling` — self-timed LRW tick active
  - `:stopped` — cycling halted (too many misses or manual stop)

  ## Hot Path (Direct ETS)

      # Write output
      Domain.write(:my_domain, {:valve, :ch1}, <<0xFF>>)

      # Read current value
      Domain.read(:my_domain, {:sensor, :ch1})
      # => {:ok, binary} | {:error, :not_found | :not_ready}

  Both bypass the gen_statem entirely via direct ETS access.

  ## Telemetry

  - `[:ethercat, :domain, :cycle, :done]` — `%{duration_us, cycle_count, completed_at_us}`
  - `[:ethercat, :domain, :cycle, :missed]` — `%{miss_count, total_miss_count, invalid_at_us}`, metadata: `%{domain, reason}`
  """

  @behaviour :gen_statem

  alias EtherCAT.Domain.Calls
  alias EtherCAT.Domain.Cycle
  alias EtherCAT.Domain.Image
  alias EtherCAT.Domain.Layout

  @type domain_id :: atom()
  @type pdo_key :: {slave_name :: atom(), pdo_name :: atom()}

  defstruct [
    :id,
    :bus,
    :period_us,
    :logical_base,
    :next_cycle_at,
    :last_cycle_started_at_us,
    :last_cycle_completed_at_us,
    :last_valid_cycle_at_us,
    :last_invalid_cycle_at_us,
    :last_invalid_reason,
    layout: Layout.new(),
    cycle_plan: nil,
    cycle_health: :healthy,
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
    - `:bus` (required) — bus server reference
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
    - `:input`  — slave reads from bus; domain tracks the slave name for change notifications
    - `:output` — slave writes to bus; no input delivery route is needed
  """
  @spec register_pdo(domain_id(), pdo_key(), pos_integer(), :input | :output) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def register_pdo(domain_id, key, size, direction) do
    safe_call(domain_id, {:register_pdo, key, size, direction})
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
    updated_at_us = System.monotonic_time(:microsecond)

    try do
      Image.write(domain_id, key, binary, updated_at_us)
    rescue
      ArgumentError -> {:error, :not_found}
    end
  end

  @doc "Read current raw value (output or input). Direct ETS — no gen_statem hop."
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

  @doc """
  Read the current raw value together with freshness metadata.

  Returns `{:error, :not_ready}` until the first input cycle completes for input
  PDOs. Output PDOs become fresh once the process image is staged.
  """
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

  @doc "Return current stats."
  @spec stats(domain_id()) :: {:ok, map()} | {:error, :not_found}
  def stats(domain_id) do
    safe_call(domain_id, :stats)
  end

  @doc """
  Return a diagnostic snapshot for a domain.

  Returns `{:ok, map}` with keys: `:id`, `:cycle_time_us`, `:state`,
  `:cycle_count`, `:miss_count`, `:total_miss_count`, `:cycle_health`,
  `:logical_base`, `:image_size`, `:expected_wkc`, `:last_valid_cycle_at_us`,
  `:last_invalid_cycle_at_us`, `:last_invalid_reason`.
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
      last_cycle_started_at_us: nil,
      last_cycle_completed_at_us: nil,
      last_valid_cycle_at_us: nil,
      last_invalid_cycle_at_us: nil,
      last_invalid_reason: nil,
      layout: Layout.new(),
      cycle_plan: nil,
      cycle_health: :healthy,
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

  def handle_event(:enter, _old, :cycling, data),
    do: {:keep_state_and_data, Cycle.enter_actions(data)}

  def handle_event(:enter, _old, :stopped, _data), do: :keep_state_and_data

  def handle_event({:call, from}, {:register_pdo, key, size, direction}, :open, data) do
    Calls.register_pdo(from, key, size, direction, data)
  end

  def handle_event({:call, from}, {:register_pdo, _, _, _}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_open}}]}
  end

  def handle_event({:call, from}, :start_cycling, state, data)
      when state in [:open, :stopped, :cycling],
      do: Calls.start_cycling(from, state, data)

  def handle_event({:call, from}, :stop_cycling, state, data)
      when state in [:open, :stopped, :cycling],
      do: Calls.stop_cycling(from, state, data)

  def handle_event(:state_timeout, :tick, :cycling, data), do: Cycle.handle_tick(data)

  def handle_event({:call, from}, :stats, state, data) do
    Calls.stats(from, state, data)
  end

  def handle_event({:call, from}, :info, state, data) do
    Calls.info(from, state, data)
  end

  def handle_event({:call, from}, {:update_cycle_time, new_us}, _state, data) do
    Calls.update_cycle_time(from, new_us, data)
  end

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  defp safe_call(domain_id, msg) do
    try do
      :gen_statem.call(via(domain_id), msg)
    catch
      :exit, {:noproc, _} -> {:error, :not_found}
    end
  end

  defp via(domain_id), do: {:via, Registry, {EtherCAT.Registry, {:domain, domain_id}}}
end
