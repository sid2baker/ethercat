# Plan: Complete EtherCAT DC Signal Implementation (SYNC1 + LATCH0/1)

## Status: ACTIVE — not yet implemented

## Context

The current implementation configures SYNC0 only. Three hard gaps prevent SYNC1 or latch
support even if a driver requests it:
- `registers.ex` has no SYNC1 or latch registers
- `driver.ex` `distributed_clocks` type is `%{sync0_pulse_ns: pos_integer()}` only
- `slave.ex` hardcodes activation byte `0x03` (sync_out + SYNC0 only)

EtherCAT's latch mechanism maps naturally to Elixir's process model: the ESC hardware
captures a timestamp when a physical LATCH pin edge fires; the slave gen_statem polls for it
on a `state_timeout` tick and fans out `{:slave_latch, name, latch_id, edge, timestamp_ns}`
messages to subscribers. No OS interrupts required.

## Terminology

- **SYNC0**: primary synchronization pulse at `0x09A0` (cycle time, ns)
- **SYNC1**: secondary pulse at `0x09A4` (offset ns from SYNC0; 0 = disabled). Acts as a
  phase-shifted derivative of SYNC0, not an independent clock.
- **LATCH0/LATCH1**: hardware input pins on ESC. Edge events are timestamped against DC
  system time. Distinct from CoE objects 0x1C32/0x1C33 ("Input Latch" in CoE context
  means PDO sampling timing relative to SYNC, not the physical LATCH pin).
- **Activation register `0x0981`**: bit0=cyclic_enable, bit1=SYNC0_out, bit2=SYNC1_out.
  `0x03` = SYNC0 only; `0x07` = SYNC0+SYNC1.

## Files to Modify

- `lib/ethercat/slave/registers.ex`
- `lib/ethercat/slave/driver.ex`
- `lib/ethercat/slave.ex`

`dc.ex` and `domain.ex` are reference only — no changes needed.

---

## Step 1 — `registers.ex`: Add SYNC1 and Latch Registers

Append after `dc_sync0_cycle_time/1` (line 303). Also fix the `dc_activation/0` doc
(currently says "SYNC0+SYNC1" — wrong; correct bit layout described below).

```elixir
@doc "SYNC1 cycle time in ns. 0 = disabled. Acts as offset from SYNC0, not independent."
@spec dc_sync1_cycle_time() :: reg()
def dc_sync1_cycle_time, do: {0x09A4, 4}

@doc "SYNC1 cycle time write — encodes `cycle_ns` as a 32-bit little-endian value."
@spec dc_sync1_cycle_time(non_neg_integer()) :: reg_write()
def dc_sync1_cycle_time(cycle_ns), do: {0x09A4, <<cycle_ns::32-little>>}

@doc """
DC latch event status register (read-only, 2 bytes).
  bit 4: LATCH0 positive edge captured
  bit 5: LATCH0 negative edge captured
  bit 8: LATCH1 positive edge captured
  bit 9: LATCH1 negative edge captured
Reading the corresponding timestamp register clears the bit.
"""
@spec dc_latch_event_status() :: reg()
def dc_latch_event_status, do: {0x09A8, 2}

@doc "LATCH0 positive edge timestamp (8 bytes, ns since DC epoch 2000-01-01)."
@spec dc_latch0_pos_time() :: reg()
def dc_latch0_pos_time, do: {0x09B0, 8}

@doc "LATCH0 negative edge timestamp."
@spec dc_latch0_neg_time() :: reg()
def dc_latch0_neg_time, do: {0x09B8, 8}

@doc "LATCH1 positive edge timestamp."
@spec dc_latch1_pos_time() :: reg()
def dc_latch1_pos_time, do: {0x09C0, 8}

@doc "LATCH1 negative edge timestamp."
@spec dc_latch1_neg_time() :: reg()
def dc_latch1_neg_time, do: {0x09C8, 8}
```

Also fix `dc_activation/0` doc:
```
# old: "Write 0x03 to enable SYNC0+SYNC1 output."
# new: "DC Activation register. bit0=cyclic_enable, bit1=SYNC0_out, bit2=SYNC1_out.
#       0x01=cyclic only, 0x03=SYNC0, 0x07=SYNC0+SYNC1."
```

---

## Step 2 — `driver.ex`: Extend `distributed_clocks` and Add `on_latch/5`

Replace `@type distributed_clocks` and update `@optional_callbacks`:

```elixir
@type latch_edge :: :pos | :neg
@type latch_config :: %{latch_id: 0 | 1, edge: latch_edge()}

@type distributed_clocks :: %{
  sync0_pulse_ns: pos_integer(),
  optional(:sync1_cycle_ns) => pos_integer(),  # SYNC1 offset ns from SYNC0; 0 or absent = disabled
  optional(:latches) => [latch_config()]        # which LATCH pin edges to poll
}

@doc """
Called when a LATCH hardware event is detected during Op.

Arguments: slave_name, config, latch_id (0|1), edge (:pos|:neg), timestamp_ns (DC ns since 2000-01-01)
"""
@callback on_latch(atom(), config(), 0 | 1, latch_edge(), non_neg_integer()) :: :ok

@optional_callbacks [on_preop: 2, on_safeop: 2, on_op: 2, mailbox_config: 1, distributed_clocks: 1, on_latch: 5]
```

Backward compatible: existing `%{sync0_pulse_ns: N}` drivers satisfy the new type.

---

## Step 3 — `slave.ex`: Struct Fields

Add to `defstruct`:

```elixir
# [{latch_id, edge}] configured by driver's distributed_clocks; nil if no latches
:active_latches,
# ms between latch polls; nil if active_latches is nil
:latch_poll_ms,
# %{{latch_id, edge} => [pid]} — updated by subscribe_latch/4 at any time
latch_subscriptions: %{},
```

Initialize in `init/1`:
```elixir
active_latches: nil,
latch_poll_ms: nil,
latch_subscriptions: %{},
```

---

## Step 4 — `slave.ex`: Rename `configure_sync0_if_needed` → `configure_dc_signals`

Returns `data` (not `:ok`) so latch config is threaded into state.

```elixir
defp configure_dc_signals(data) do
  case data.dc_cycle_ns && invoke_driver_call(data, :distributed_clocks) do
    nil -> data
    dc_spec ->
      cycle_ns = data.dc_cycle_ns
      pulse_ns = Map.get(dc_spec, :sync0_pulse_ns, 0)
      sync1_ns = Map.get(dc_spec, :sync1_cycle_ns, 0)
      activation = if sync1_ns > 0, do: 0x07, else: 0x03
      start_time = System.os_time(:nanosecond) - @ethercat_epoch_offset_ns + 100_000

      Bus.transaction(
        data.bus,
        Transaction.new()
        |> Transaction.fpwr(data.station, Registers.dc_sync0_cycle_time(cycle_ns))
        |> Transaction.fpwr(data.station, Registers.dc_sync1_cycle_time(sync1_ns))
        |> Transaction.fpwr(data.station, Registers.dc_pulse_length(pulse_ns))
        |> Transaction.fpwr(data.station, Registers.dc_sync0_start_time(start_time))
        |> Transaction.fpwr(data.station, Registers.dc_activation(activation))
      )

      latches = Map.get(dc_spec, :latches, [])
      active = if latches == [], do: nil, else: Enum.map(latches, &{&1.latch_id, &1.edge})

      %{data | active_latches: active, latch_poll_ms: if(active, do: 1, else: nil)}
  end
end
```

---

## Step 5 — `slave.ex`: Update `:safeop` Enter Handler

```elixir
def handle_event(:enter, _old, :safeop, data) do
  invoke_driver(data, :on_safeop)
  new_data = configure_dc_signals(data)
  {:keep_state, new_data}
end
```

---

## Step 6 — `slave.ex`: Update `:op` Enter Handler

```elixir
def handle_event(:enter, _old, :op, data) do
  invoke_driver(data, :on_op)
  actions = if data.latch_poll_ms,
    do: [{:state_timeout, data.latch_poll_ms, :latch_poll}],
    else: []
  {:keep_state_and_data, actions}
end
```

---

## Step 7 — `slave.ex`: Latch Poll Handler and Helpers

```elixir
@latch_masks %{
  {0, :pos} => 0x0010,
  {0, :neg} => 0x0020,
  {1, :pos} => 0x0100,
  {1, :neg} => 0x0200
}

def handle_event(:state_timeout, :latch_poll, :op, data) do
  case Bus.transaction(data.bus, Transaction.fprd(data.station, Registers.dc_latch_event_status()), data.latch_poll_ms * 1_000) do
    {:ok, [%{data: <<status::16-little>>, wkc: wkc}]} when wkc > 0 ->
      dispatch_latch_events(data, status)
    _ ->
      :ok
  end
  {:keep_state_and_data, [{:state_timeout, data.latch_poll_ms, :latch_poll}]}
end

defp dispatch_latch_events(data, status) do
  Enum.each(data.active_latches, fn {latch_id, edge} = key ->
    mask = @latch_masks[key]
    if latch_event_set?(status, key) do
      # Reading timestamp register clears the event bit in hardware
      reg = latch_time_register(latch_id, edge)
      case Bus.transaction(data.bus, Transaction.fprd(data.station, reg), data.latch_poll_ms * 1_000) do
        {:ok, [%{data: <<ts::64-little>>, wkc: wkc}]} when wkc > 0 ->
          msg = {:slave_latch, data.name, latch_id, edge, ts}
          data.latch_subscriptions
          |> Map.get(key, [])
          |> Enum.each(&send(&1, msg))
          invoke_driver(data, :on_latch, [latch_id, edge, ts])
        _ -> :ok
      end
    end
  end)
end

defp latch_time_register(0, :pos), do: Registers.dc_latch0_pos_time()
defp latch_time_register(0, :neg), do: Registers.dc_latch0_neg_time()
defp latch_time_register(1, :pos), do: Registers.dc_latch1_pos_time()
defp latch_time_register(1, :neg), do: Registers.dc_latch1_neg_time()

defp latch_event_set?(status, {0, :pos}), do: match?(<<_::4, 1::1, _::11>>, <<status::16-little>>)
defp latch_event_set?(status, {0, :neg}), do: match?(<<_::5, 1::1, _::10>>, <<status::16-little>>)
defp latch_event_set?(status, {1, :pos}), do: match?(<<_::8, 1::1, _::7>>, <<status::16-little>>)
defp latch_event_set?(status, {1, :neg}), do: match?(<<_::9, 1::1, _::6>>, <<status::16-little>>)
```

---

## Step 8 — `slave.ex`: Public API

```elixir
@doc "Subscribe to LATCH hardware pin events on this slave."
@spec subscribe_latch(atom(), 0 | 1, :pos | :neg, pid()) :: :ok
def subscribe_latch(slave_name, latch_id, edge, pid) do
  :gen_statem.call(via(slave_name), {:subscribe_latch, latch_id, edge, pid})
end

# handler:
def handle_event({:call, from}, {:subscribe_latch, latch_id, edge, pid}, _state, data) do
  key = {latch_id, edge}
  subs = [pid | Map.get(data.latch_subscriptions, key, [])]
  new_data = %{data | latch_subscriptions: Map.put(data.latch_subscriptions, key, subs)}
  {:keep_state, new_data, [{:reply, from, :ok}]}
end
```

---

## Implementation Order

Execute in order — each step keeps the system compiling:

1. `registers.ex` — add 6 register functions + fix `dc_activation/0` doc
2. `driver.ex` — extend type, add `on_latch/5`, update `@optional_callbacks`
3. `slave.ex` defstruct + `init/1` — add 3 new fields
4. `slave.ex` — rename/rewrite `configure_dc_signals/1`
5. `slave.ex` — update `:safeop` enter handler
6. `slave.ex` — update `:op` enter + add `state_timeout :latch_poll` handler
7. `slave.ex` — add `dispatch_latch_events/2`, `latch_time_register/2`, `@latch_masks`
8. `slave.ex` — add `subscribe_latch/4` + call handler

## Verification

```bash
mix compile --warnings-as-errors
mix test

# Register address sanity (add to test suite):
# Registers.dc_sync1_cycle_time() == {0x09A4, 4}
# Registers.dc_latch_event_status() == {0x09A8, 2}
# Registers.dc_latch1_neg_time() == {0x09C8, 8}
```

Hardware smoke test: use a driver that returns `latches: [%{latch_id: 0, edge: :pos}]`
from `distributed_clocks/1`, subscribe, and verify `{:slave_latch, name, 0, :pos, ts_ns}` messages.

## Open Questions / Caveats

- **SYNC1 semantics**: the ESC datasheet §6.5 says "SYNC1 can be derived from SYNC0 with
  configurable delays". The `0x09A4` register is labelled "SYNC1 cycle time" but in practice
  it configures the phase offset from SYNC0. The name `sync1_cycle_ns` may be misleading.
- **CoE sync mode (0x1C32/0x1C33)**: this plan only configures ESC hardware registers. For
  servo drives, the slave firmware must also be configured via SDO to use DC SYNC mode.
  This requires writing `0x1C32[1]` (output sync mode) and `0x1C33[1]` (input sync mode).
  Currently not implemented.
- **Latch poll granularity**: 1 ms poll interval is the minimum practical with BEAM. Physical
  ESC captures at 10 ns resolution; only the first unread edge per poll window is visible.
