# EtherCAT.Domain — Agent Context Briefing

## Purpose

`EtherCAT.Domain` is a `gen_statem` (`:handle_event_function` + `:state_enter` mode) that
owns one flat LRW process image and runs the self-timed cyclic exchange for all slaves
registered to it. One Domain per configured domain ID. Domains register in
`EtherCAT.Registry` under `{:domain, id}` and create an ETS table named after `id`.

Supervised under `EtherCAT.SessionSupervisor` as `:temporary` (session-scoped). Started by
Master in `do_configure/1` before any slave is spawned, so slaves can call
`register_pdo/4` during their own `:preop` init.

---

## States and Transitions

```
:open → :cycling  (via start_cycling/1 call)
:cycling → :stopped  (consecutive miss threshold, or stop_cycling/1)
:stopped → :cycling  (via start_cycling/1 call — miss_count resets)
```

| State | Description |
|-------|-------------|
| `:open` | Accepting PDO registrations. Not yet cycling. `stop_cycling/1` is a no-op. |
| `:cycling` | Self-timed LRW tick active. Process image exchanged each period. |
| `:stopped` | Cycling halted (too many misses or manual stop). PDO registrations preserved. |

PDO registration is **only allowed in `:open`** state. Any `register_pdo/4` call in `:cycling` or `:stopped` returns `{:error, :not_open}`.

---

## PDO Registration

Called by `Slave` in its `:preop` enter handler via `Domain.register_pdo/4`:

```elixir
Domain.register_pdo(domain_id, {slave_name, pdo_name}, size_bytes, :input | :output)
# → {:ok, logical_offset}
```

The returned `logical_offset` is written directly to the FMMU register in the same `:preop`
callback — no async coordination needed. The domain assigns offsets sequentially in
registration order.

**ETS insert on registration:**
- Output PDOs: `{key, <<0::size*8>>, nil}` — zero-filled, no pid tracking.
- Input PDOs: `{key, :unset, slave_pid}` — `:unset` until first cycle completes.

---

## Cycle Mechanics

Entry into `:cycling` arms a `state_timeout` for `period_us` microseconds. The current
runtime uses BEAM millisecond timers, so `cycle_time_us` must be a whole-millisecond
value (`>= 1_000`, divisible by `1_000`). On each `:tick`:

1. **Build frame** (`build_frame/3`): constructs output binary using iodata — patches
   output values from ETS into a zero-filled frame without intermediate allocation.
2. **Build transaction**: one LRW datagram for the full process image.
3. **Realtime transaction** (`Bus.transaction/3`): sends the cycle transaction with a timeout budget slightly below cycle period; stale ticks are dropped.
4. **Dispatch inputs** (`dispatch_inputs/4`): for each input slice, compares new value
   against ETS; on change, updates ETS and sends
   `{:domain_input, domain_id, key, old_raw | :unset, new_raw}` to the slave pid.
5. **Schedule next tick**: uses `next_cycle_at + period_us` drift-compensated schedule
   (not `now + period_us`) to prevent period drift accumulation.

On cycle failure (LRW mismatch or transport error):
- Increments `miss_count` and `total_miss_count`.
- Emits `:telemetry` event `[:ethercat, :domain, :cycle, :missed]`.
- If `miss_count >= miss_threshold`: logs error, transitions to `:stopped`.

On success: resets `miss_count` to 0, emits `[:ethercat, :domain, :cycle, :done]`.

---

## Hot Path (Direct ETS — No gen_statem Hop)

```elixir
# Write output (from application → bus)
Domain.write(:my_domain, {:valve_1, :outputs}, <<0xFF>>)
# → :ok | {:error, :not_found}

# Read current value (application reads any PDO)
Domain.read(:my_domain, {:sensor_1, :channels})
# → {:ok, binary} | {:error, :not_found | :not_ready}
```

Both functions bypass the gen_statem entirely via direct `:ets.update_element/3` and
`:ets.lookup/2`. The ETS table is `:public` with `read_concurrency: true` and
`write_concurrency: true`.

`:not_ready` is returned for input PDOs that have not yet completed a cycle (value is
`:unset` in ETS).

---

## ETS Table Schema

```
table name : domain_id (atom — :named_table, :public, :set)
record     : {key, value, slave_pid}
  key       — {slave_name :: atom(), pdo_name :: atom()}
  value     — binary() | :unset
              binary for outputs (zero-filled initially)
              :unset for inputs until first cycle, then binary
  slave_pid — pid() for inputs (notified on change)
              nil for outputs
```

---

## Struct Fields

```elixir
%EtherCAT.Domain{
  id:               atom(),              # Domain ID; also ETS table name
  bus:              pid(),               # Bus server reference
  period_us:        pos_integer(),       # Cycle period in microseconds (whole milliseconds only)
  logical_base:     non_neg_integer(),   # LRW logical address base (default 0)
  next_cycle_at:    integer() | nil,     # Monotonic target time for next tick
  layout:           EtherCAT.Domain.Layout.t(),          # Mutable registration-time layout
  cycle_plan:       EtherCAT.Domain.Layout.CyclePlan.t(), # Frozen LRW plan
  miss_count:       non_neg_integer(),   # Consecutive misses (resets on success)
  miss_threshold:   pos_integer(),       # Stop after this many consecutive misses
  total_miss_count: non_neg_integer(),   # Lifetime miss count (never resets)
  cycle_count:      non_neg_integer(),   # Successful cycle count
  table:            :ets.tid() | nil,
}
```

---

## Telemetry Events

| Event | Measurements | Metadata |
|-------|-------------|---------|
| `[:ethercat, :domain, :cycle, :done]` | `%{duration_us: us, cycle_count: n}` | `%{domain: id}` |
| `[:ethercat, :domain, :cycle, :missed]` | `%{miss_count: n}` | `%{domain: id, reason: term}` |
## Public API Summary

| Function | Description |
|----------|-------------|
| `register_pdo/4` | Register a PDO slice. Returns `{:ok, logical_offset}`. Only valid in `:open`. |
| `start_cycling/1` | Begin the self-timed LRW cycle. Transitions `:open`/`:stopped` → `:cycling`. |
| `stop_cycling/1` | Halt cycling. Idempotent in `:open`/`:stopped`; `:cycling` → `:stopped`. |
| `write/3` | Direct ETS output write. No gen_statem hop. |
| `read/2` | Direct ETS read of any PDO. No gen_statem hop. |
| `stats/1` | Returns `{:ok, %{state, cycle_count, miss_count, total_miss_count, image_size, expected_wkc}}`. |

---

## Key Design Decisions

**Why `Bus.transaction/3` for the cycle frame?**
The domain cycle is realtime work. `transaction/3` (period-derived staleness budget) is
appropriate for the LRW frame. Reliable configuration traffic uses `Bus.transaction/2`;
cyclic frames should not share frames with it.

**Why drift-compensated scheduling (`next_cycle_at + period_us`, not `now + period_us`)?**
`now + period_us` accumulates jitter because each cycle is scheduled relative to when the
previous LRW completed (variable). Anchoring to a fixed base time prevents drift over
thousands of cycles.

**Why `state_timeout` instead of `Process.send_after`?**
`state_timeout` is automatically cancelled on state transition. Transitioning to `:stopped`
implicitly cancels the pending tick — no manual cleanup needed.

---

## Known Gaps

- **No per-PDO timestamp**: Domain does not record when each input last changed. Subscribers
  receive raw binary; staleness detection is the application's responsibility.
- **No backpressure on slave pid**: `send/2` to slave pid is fire-and-forget. If a slave is
  slow, input change messages queue in its mailbox without flow control.
- **Single LRW per domain**: all registered PDOs must fit in one LRW frame. Very large process
  images require splitting into multiple domains.
- **Single-frame guard only**: oversized LRW images are now rejected before cycling starts,
  but the domain still cannot segment one logical image across multiple datagrams.
- **Sub-byte PDO limitation**: `image_size` is byte-granular. Sub-byte (1-bit) PDOs are
  padded to 1 byte by the slave before registration; the domain does not handle bit-level
  packing natively.
