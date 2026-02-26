defmodule EtherCAT.Domain do
  @moduledoc """
  Self-timed cyclic process image exchange for EtherCAT slaves.

  A Domain manages a contiguous logical process image (LRW address space) and
  drives its own cycle period via `state_timeout` — no external `Process.sleep`
  loop is needed. Multiple domains with independent periods can coexist on the
  same Link.

  ## Lifecycle

  1. Start the domain under `EtherCAT.DomainSupervisor`.
  2. Optionally call `set_default/1` to make it the target for `:default` PDO groups.
  3. Advance slaves to `:safeop` — each slave self-registers its PDOs with their
     declared domain at `:safeop` entry.
  4. Call `start_cyclic/1` to arm the period timer.
  5. Read inputs and write outputs via `get_inputs/2` and `put_outputs/3` directly
     against the ETS table — no gen_statem hop on the hot path.

  ## ETS table

  Each domain owns a public ETS table named after its `:id`. Rows:

      {station :: non_neg_integer(),
       outputs :: binary(),
       inputs  :: binary(),
       updated_at :: integer()}   # monotonic_time(:microsecond)

  ## Logical address space

  The LRW datagram covers `[logical_base, logical_base + image_size)`. All domains
  sharing a link must have non-overlapping logical address ranges. The `:logical_base`
  option (default `0`) is set by the application.

  ## Example

      # In application startup (after Master.start + go_operational):
      link = EtherCAT.Master.link()

      DynamicSupervisor.start_child(EtherCAT.DomainSupervisor,
        {EtherCAT.Domain, id: :fast, link: link, period: 1})

      EtherCAT.Domain.set_default(:fast)

      # Slaves self-register at :safeop — no manual calls needed

      EtherCAT.Domain.start_cyclic(:fast)
      EtherCAT.Domain.subscribe(:fast)

      receive do
        {:ethercat_domain, :fast, :cycle_done} ->
          {:ok, raw, _ts} = EtherCAT.Domain.get_inputs(:fast, 0x1001)
          EtherCAT.Domain.put_outputs(:fast, 0x1002, MyDriver.encode_outputs(raw))
      end
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.Link
  alias EtherCAT.Link.Transaction
  alias EtherCAT.Slave.Registers

  @type domain_id :: atom()
  @type station :: non_neg_integer()

  defstruct [
    :id,
    :link,
    :period_us,
    :logical_base,
    :next_cycle_at,
    :layout,
    :subscribers,
    :miss_count,
    :miss_threshold,
    :cycle_count,
    :table
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
  Start a Domain process.

  ## Options

    - `:id` (required) — unique atom; also the ETS table name and Registry key
    - `:link` (required) — pid of the Link process (from `EtherCAT.Master.link/0`)
    - `:period` (required) — cycle period in milliseconds
    - `:logical_base` — LRW logical address base, default `0`
    - `:miss_threshold` — consecutive misses before stopping, default `100`
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  # -- Public API ------------------------------------------------------------

  @doc """
  Nominate `domain_id` as the target for `:default` PDO groups.

  Slaves whose driver returns `domain: :default` in their PDO profile will
  register with this domain when they enter `:safeop`.
  """
  @spec set_default(domain_id()) :: :ok
  def set_default(domain_id) do
    Registry.register(EtherCAT.Registry, {:domain, :default}, domain_id)
    :ok
  end

  @doc """
  Register a slave PDO group with this domain.

  Called automatically by `EtherCAT.Slave` at `:safeop` entry. Writes the SM
  and FMMU registers for the slave, then extends the domain's logical process
  image layout.

  `pdo` is one entry from the `pdos` list returned by `driver.process_data_profile/0`.
  """
  @spec register_pdo(domain_id(), station(), map(), pid()) :: :ok | {:error, term()}
  def register_pdo(domain_id, station, pdo, link) do
    via = {:via, Registry, {EtherCAT.Registry, {:domain, domain_id}}}
    :gen_statem.call(via, {:register_pdo, station, pdo, link})
  end

  @doc """
  Arm the cyclic LRW timer. Call after all expected slaves have registered.

  Transitions the domain from `:open` to `:cycling`. The first frame is sent
  after one full period.
  """
  @spec start_cyclic(domain_id()) :: :ok | {:error, term()}
  def start_cyclic(domain_id) do
    via = {:via, Registry, {EtherCAT.Registry, {:domain, domain_id}}}
    :gen_statem.call(via, :start_cyclic)
  end

  @doc "Halt cyclic exchange. Domain stays alive; call `start_cyclic/1` to resume."
  @spec stop_cyclic(domain_id()) :: :ok
  def stop_cyclic(domain_id) do
    via = {:via, Registry, {EtherCAT.Registry, {:domain, domain_id}}}
    :gen_statem.call(via, :stop_cyclic)
  end

  @doc """
  Write raw output bytes for `station`. Takes effect on the next cycle.

  Direct ETS write — no gen_statem hop. Safe to call from any process.
  """
  @spec put_outputs(domain_id(), station(), binary()) :: :ok
  def put_outputs(domain_id, station, data) when is_atom(domain_id) and is_binary(data) do
    :ets.update_element(domain_id, station, {2, data})
    :ok
  end

  @doc """
  Read the last received raw input bytes for `station`.

  Direct ETS read — no gen_statem hop. Returns `{:ok, binary, updated_at}` where
  `updated_at` is `System.monotonic_time(:microsecond)` of the last cycle that
  received data, or `{:error, :not_found}` if the station is not registered.
  """
  @spec get_inputs(domain_id(), station()) ::
          {:ok, binary(), integer()} | {:error, :not_found}
  def get_inputs(domain_id, station) when is_atom(domain_id) do
    case :ets.lookup(domain_id, station) do
      [{^station, _out, inputs, ts}] -> {:ok, inputs, ts}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Subscribe the calling process to receive `{:ethercat_domain, domain_id, :cycle_done}`
  after each successful cycle.
  """
  @spec subscribe(domain_id()) :: :ok
  def subscribe(domain_id) do
    via = {:via, Registry, {EtherCAT.Registry, {:domain, domain_id}}}
    :gen_statem.call(via, {:subscribe, self()})
  end

  @doc "Unsubscribe from cycle notifications."
  @spec unsubscribe(domain_id()) :: :ok
  def unsubscribe(domain_id) do
    via = {:via, Registry, {EtherCAT.Registry, {:domain, domain_id}}}
    :gen_statem.call(via, {:unsubscribe, self()})
  end

  @doc "Return current stats for the domain."
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
    id            = Keyword.fetch!(opts, :id)
    link          = Keyword.fetch!(opts, :link)
    period_ms     = Keyword.fetch!(opts, :period)
    logical_base  = Keyword.get(opts, :logical_base, 0)
    miss_threshold = Keyword.get(opts, :miss_threshold, 100)

    table = :ets.new(id, [
      :set, :public, :named_table,
      {:write_concurrency, true},
      {:read_concurrency, true}
    ])

    # Register in EtherCAT.Registry so slaves and callers can find this domain by name
    Registry.register(EtherCAT.Registry, {:domain, id}, id)

    data = %__MODULE__{
      id: id,
      link: link,
      period_us: period_ms * 1000,
      logical_base: logical_base,
      next_cycle_at: nil,
      layout: %{image_size: 0, outputs: [], inputs: []},
      subscribers: [],
      miss_count: 0,
      miss_threshold: miss_threshold,
      cycle_count: 0,
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
    # Ceiling division — never fire before the boundary
    delay_ms = div(delay_us + 999, 1000)
    {:keep_state_and_data, [{:state_timeout, delay_ms, :tick}]}
  end

  def handle_event(:enter, _old, :stopped, _data), do: :keep_state_and_data

  # -- :open — accept PDO registrations -------------------------------------

  def handle_event({:call, from}, {:register_pdo, station, pdo, link}, :open, data) do
    {new_layout, out_offset, in_offset} = extend_layout(data.layout, pdo)

    with :ok <- write_sms(link, station, pdo.sms),
         :ok <- write_fmmus(link, station, pdo.fmmus, out_offset, in_offset) do
      out_size = Map.get(pdo, :outputs_size, 0)
      :ets.insert(data.table, {station, :binary.copy(<<0>>, out_size), <<>>, 0})
      {:keep_state, %{data | layout: new_layout}, [{:reply, from, :ok}]}
    else
      {:error, _} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def handle_event({:call, from}, {:register_pdo, _, _, _}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_open}}]}
  end

  def handle_event({:call, from}, :start_cyclic, :open, data) do
    if data.layout.image_size == 0 do
      {:keep_state_and_data, [{:reply, from, {:error, :no_pdos_registered}}]}
    else
      now = System.monotonic_time(:microsecond)
      new_data = %{data | next_cycle_at: now + data.period_us}
      {:next_state, :cycling, new_data, [{:reply, from, :ok}]}
    end
  end

  def handle_event({:call, from}, :start_cyclic, :cycling, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_cycling}}]}
  end

  # -- :cycling — self-timed LRW exchange ------------------------------------

  def handle_event(:state_timeout, :tick, :cycling, data) do
    %{image_size: size, outputs: out_slices, inputs: in_slices} = data.layout
    image = build_image(size, out_slices, data.table)
    t0 = System.monotonic_time(:microsecond)

    result = Link.transaction(data.link, &Transaction.lrw(&1, data.logical_base, image))
    next_at = data.next_cycle_at + data.period_us

    # Compute next state_timeout regardless of result — drift-free re-arm
    now_after = System.monotonic_time(:microsecond)
    delay_us = max(0, next_at - now_after)
    delay_ms = div(delay_us + 999, 1000)
    next_timeout = [{:state_timeout, delay_ms, :tick}]

    case result do
      {:ok, [%{data: response, wkc: wkc}]} when wkc > 0 ->
        now = System.monotonic_time(:microsecond)
        extract_inputs(response, in_slices, data.table, now)
        notify_subscribers(data)
        duration_us = now - t0
        :telemetry.execute(
          [:ethercat, :domain, :cycle, :done],
          %{duration_us: duration_us, cycle_count: data.cycle_count + 1},
          %{domain: data.id}
        )
        new_data = %{data |
          cycle_count: data.cycle_count + 1,
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
        new_data = %{data | miss_count: data.miss_count + 1, next_cycle_at: next_at}

        if new_data.miss_count >= data.miss_threshold do
          Logger.error(
            "[Domain #{data.id}] #{data.miss_threshold} consecutive missed cycles — stopping"
          )
          {:next_state, :stopped, new_data}
        else
          {:keep_state, new_data, next_timeout}
        end
    end
  end

  def handle_event({:call, from}, :stop_cyclic, :cycling, data) do
    {:next_state, :stopped, data, [{:reply, from, :ok}]}
  end

  # -- :stopped --------------------------------------------------------------

  def handle_event({:call, from}, :start_cyclic, :stopped, data) do
    now = System.monotonic_time(:microsecond)
    new_data = %{data | next_cycle_at: now + data.period_us, miss_count: 0}
    {:next_state, :cycling, new_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :stop_cyclic, :stopped, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  # -- Subscribe / unsubscribe (any state) -----------------------------------

  def handle_event({:call, from}, {:subscribe, pid}, _state, data) do
    subs = if pid in data.subscribers, do: data.subscribers, else: [pid | data.subscribers]
    {:keep_state, %{data | subscribers: subs}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:unsubscribe, pid}, _state, data) do
    {:keep_state, %{data | subscribers: List.delete(data.subscribers, pid)},
     [{:reply, from, :ok}]}
  end

  # -- Stats (any state) -----------------------------------------------------

  def handle_event({:call, from}, :stats, state, data) do
    stats = %{
      state: state,
      cycle_count: data.cycle_count,
      miss_count: data.miss_count,
      image_size: data.layout.image_size
    }
    {:keep_state_and_data, [{:reply, from, {:ok, stats}}]}
  end

  # -- Catch-all -------------------------------------------------------------

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # -- Image assembly --------------------------------------------------------

  defp build_image(size, out_slices, table) do
    image = :binary.copy(<<0>>, size)

    Enum.reduce(out_slices, image, fn %{station: s, log_offset: off, size: n}, acc ->
      out =
        case :ets.lookup(table, s) do
          [{^s, outputs, _, _}] -> binary_pad(outputs, n)
          [] -> :binary.copy(<<0>>, n)
        end

      <<pre::binary-size(off), _::binary-size(n), rest::binary>> = acc
      <<pre::binary, out::binary, rest::binary>>
    end)
  end

  defp extract_inputs(response, in_slices, table, now) do
    Enum.each(in_slices, fn %{station: s, log_offset: off, size: n} ->
      <<_::binary-size(off), data::binary-size(n), _::binary>> = response
      # update_element with a list is atomic — no partial read possible
      :ets.update_element(table, s, [{3, data}, {4, now}])
    end)
  end

  defp binary_pad(data, size) when byte_size(data) >= size, do: binary_part(data, 0, size)
  defp binary_pad(data, size), do: data <> :binary.copy(<<0>>, size - byte_size(data))

  defp notify_subscribers(data) do
    msg = {:ethercat_domain, data.id, :cycle_done}
    Enum.each(data.subscribers, &send(&1, msg))
  end

  # -- Layout building -------------------------------------------------------

  # Extend the layout with a new PDO group. Outputs occupy the lower addresses,
  # inputs the upper — matching the ProcessImage convention.
  # Returns {new_layout, output_logical_offset, input_logical_offset}.
  defp extend_layout(%{outputs: outs, inputs: ins} = layout, pdo) do
    out_size = Map.get(pdo, :outputs_size, 0)
    in_size  = Map.get(pdo, :inputs_size, 0)

    # Count total output bytes already allocated to find where new outputs go.
    # Outputs are always packed before inputs in the image.
    current_out_total = Enum.sum(Enum.map(outs, & &1.size))
    current_in_total  = Enum.sum(Enum.map(ins,  & &1.size))

    # Shift all existing input slices up if we are adding more outputs
    # (new slave's outputs come before all inputs in the global image).
    shifted_ins =
      if out_size > 0 do
        Enum.map(ins, fn s -> %{s | log_offset: s.log_offset + out_size} end)
      else
        ins
      end

    out_offset = current_out_total
    in_offset  = current_out_total + out_size + current_in_total

    new_outs =
      if out_size > 0,
        do: outs ++ [%{station: nil, log_offset: out_offset, size: out_size}],
        else: outs

    new_ins =
      if in_size > 0,
        do: shifted_ins ++ [%{station: nil, log_offset: in_offset, size: in_size}],
        else: shifted_ins

    # We need station in the slices — will be filled in by caller
    new_outs = fill_station(new_outs, pdo, :outputs_size, out_offset)
    new_ins  = fill_station(new_ins,  pdo, :inputs_size,  in_offset)

    new_size = current_out_total + out_size + current_in_total + in_size
    new_layout = %{layout | image_size: new_size, outputs: new_outs, inputs: new_ins}

    {new_layout, out_offset, in_offset}
  end

  defp fill_station(slices, pdo, size_key, offset) do
    Enum.map(slices, fn s ->
      if s.station == nil and s.log_offset == offset and s.size == Map.get(pdo, size_key, 0) do
        %{s | station: Map.get(pdo, :station)}
      else
        s
      end
    end)
  end

  # -- SM / FMMU register writes ---------------------------------------------

  defp write_sms(link, station, sms) do
    Enum.reduce_while(sms, :ok, fn {idx, start, len, ctrl}, :ok ->
      reg = <<start::16-little, len::16-little, ctrl::8, 0::8, 0x01::8, 0::8>>

      case write_reg(link, station, {Registers.sm(idx), 8}, reg) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp write_fmmus(link, station, fmmus, out_offset, in_offset) do
    Enum.reduce_while(fmmus, :ok, fn {idx, phys, size, dir}, :ok ->
      type = if dir == :read, do: 0x01, else: 0x02
      log  = if dir == :read, do: in_offset, else: out_offset

      reg =
        <<log::32-little, size::16-little, 0::8, 7::8,
          phys::16-little, 0::8, type::8, 0x01::8, 0::24>>

      case write_reg(link, station, {Registers.fmmu(idx), 16}, reg) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp write_reg(link, station, {addr, _size}, data) do
    case Link.transaction(link, &Transaction.fpwr(&1, station, addr, data)) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 -> :ok
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err -> err
    end
  end
end
