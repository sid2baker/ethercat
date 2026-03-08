# Distributed Clocks Public API Proposal

## Goal

Provide a user-facing API that is:

1. honest about what the library can guarantee
2. aligned with EtherCAT DC concepts
3. understandable without requiring ESC register knowledge
4. split cleanly between:
   - **global DC infrastructure**
   - **per-slave sync usage**
   - **runtime observability**

This proposal is intentionally shaped by the current implementation limits:

- pure Elixir
- raw sockets
- current domain cycle floor is effectively **1 ms**

That means the API must not pretend to offer hard real-time sub-cycle actuation from BEAM.

---

## Core Design Principle

The term **Distributed Clocks** is correct for the master-wide clock infrastructure.

But at the slave level, the user usually does **not** want to configure “distributed clocks”.
The user wants to configure one of these things:

- sync outputs
- sync phase
- latch capture
- device application sync mode

So the API should use:

- `dc:` for **master-wide clock infrastructure**
- `sync:` for **per-slave user intent**

That is why `EtherCAT.DC.SlaveConfig` is the wrong name.

It leaks implementation vocabulary into the wrong abstraction level.

---

## Performance Envelope

### What the current architecture can do honestly

With the current domain runtime, the practical floor is:

- **1 ms cycle time**

That is because:

- the domain loop is BEAM-scheduled
- the current public domain API is millisecond-shaped
- the cyclic data path is not built as a sub-millisecond RT engine

### What DC is still useful for at 1 ms

Even at 1 ms, DC is still valuable because it gives you:

1. **aligned slave-side actuation**
   multiple slaves can apply outputs on the same hardware time base
2. **aligned slave-side sampling**
   inputs can be sampled at a defined sync event instead of “whenever the frame arrived”
3. **exact hardware timestamps**
   ESC latch events can record the real hardware event time

So DC is still meaningful for:

- distributed I/O with low jitter requirements
- timestamping external events
- moderate motion setups that run at 1 ms

### What the current architecture should not promise

It should not promise:

- 250 us or 100 us master-driven cyclic control
- arbitrary sub-cycle “set this output at time T” semantics from BEAM
- full servo-grade motion semantics without more runtime work

If the library wants to compete in that space later, the cycle engine likely needs a different architecture.

---

## The User Problem This API Should Solve

### Problem

A machine has:

- one drive slave controlling a conveyor
- one digital output terminal triggering a print head
- one sensor terminal detecting a product edge

Requirements:

1. the drive consumes new targets at **1 ms**
2. the print trigger must happen at a defined phase relative to that cycle
3. the product edge must be timestamped precisely in hardware time
4. the application must know whether clocks are actually locked before operation starts

The user should not need to know:

- `0x0928`
- `0x0980`
- `0x0981`
- `0x09A0`
- `0x1C32`
- `0x1C33`

The API should express the user's intent directly.

---

## Proposed Public API

## 1. Master-level DC config

Use a real struct instead of a bare `dc_cycle_ns`.

```elixir
%EtherCAT.DC.Config{
  cycle_ns: 1_000_000,
  await_lock?: true,
  lock_policy: :recovering,
  lock_threshold_ns: 100,
  lock_timeout_ms: 5_000,
  warmup_cycles: 0
}
```

Usage:

```elixir
EtherCAT.start(
  interface: "eth1",
  dc: %EtherCAT.DC.Config{
    cycle_ns: 1_000_000,
    await_lock?: true,
    lock_policy: :recovering,
    lock_threshold_ns: 100
  },
  domains: [
    %EtherCAT.Domain.Config{id: :main, cycle_time_us: 1_000}
  ],
  slaves: [...]
)
```

### Semantics

- `cycle_ns`
  - global DC sync cycle
  - shared reference period for slaves that opt into sync usage
- `await_lock?`
  - if `true`, activation does not complete until DC lock converges or times out
- `lock_policy`
  - runtime reaction when DC lock is later lost after activation
- `lock_threshold_ns`
  - acceptable absolute sync difference from `0x092C`
- `lock_timeout_ms`
  - fail activation if lock does not converge in time
- `warmup_cycles`
  - optional pre-compensation cycles before final OP
  - likely `0` initially, but the API should reserve the concept

### Why this is better than `dc_cycle_ns`

Because it makes the real DC contract explicit:

- not just “cycle exists”
- also “lock matters”
- also “status matters”

---

## 2. Domain config should move to microseconds

Current `period_ms` is too coarse for anything timing-sensitive.

Proposed breaking change:

```elixir
%EtherCAT.Domain.Config{
  id: :main,
  cycle_time_us: 1_000,
  miss_threshold: 500
}
```

### Why

- user intent is a cycle time, not “milliseconds”
- DC is nanosecond-scale, so domain timing should at least be microsecond-shaped
- even if the runtime still enforces `>= 1_000 us` for now, the API becomes honest and extensible

### Current implementation note

The runtime should validate:

- `cycle_time_us >= 1_000`

for now.

That keeps the API future-compatible without making false performance claims.

---

## 3. Per-slave sync config

This should live on `EtherCAT.Slave.Config` under a `:sync` field.

Not under `DC`.

```elixir
%EtherCAT.Slave.Config{
  name: :axis,
  driver: MyDrive,
  process_data: {:all, :main},
  target_state: :op,
  sync: %EtherCAT.Slave.Sync.Config{
    mode: :sync0,
    sync0: %{pulse_ns: 5_000, shift_ns: 0}
  }
}
```

### Proposed struct

```elixir
%EtherCAT.Slave.Sync.Config{
  mode: :free_run | :sync0 | :sync1 | nil,
  sync0: %{pulse_ns: pos_integer(), shift_ns: integer()} | nil,
  sync1: %{offset_ns: non_neg_integer()} | nil,
  latches: %{optional(atom()) => {0 | 1, :pos | :neg}}
}
```

### Why this naming is better

- `mode`
  - describes how the slave application should use sync
- `sync0`, `sync1`
  - user-facing signals, not abstract “distributed clocks”
- `latches`
  - user names matter more than ESC pin numbers

---

## 4. Named latches

Yes, latch names should be user-facing.

Example:

```elixir
%EtherCAT.Slave.Sync.Config{
  latches: %{
    product_edge: {0, :pos},
    home_marker: {1, :neg}
  }
}
```

This lets the user subscribe by semantic name:

```elixir
EtherCAT.subscribe(:photoeye, :product_edge)
```

and receive:

```elixir
{:ethercat_latch, :photoeye, :product_edge, timestamp_ns}
```

### Why this is better

Most applications do not care that:

- it was ESC LATCH0
- on the positive edge

They care that:

- it was the `:product_edge`

The runtime can still store the low-level mapping internally.

---

## 5. Runtime observability API

The user needs a first-class DC status surface.

### Proposed API

```elixir
EtherCAT.dc_status()
EtherCAT.await_dc_locked(timeout_ms \\ 5_000)
EtherCAT.reference_clock()
EtherCAT.subscribe(slave_name, signal_or_latch_name, pid \\ self())
```

### Proposed return types

```elixir
%EtherCAT.DC.Status{
  enabled?: true,
  reference_clock: :axis,
  reference_station: 0x1001,
  cycle_ns: 1_000_000,
  locked?: true,
  max_sync_diff_ns: 42,
  last_sync_check_at: 1_234_567_890
}
```

`EtherCAT.reference_clock/0`:

```elixir
{:ok, %{name: :axis, station: 0x1001}}
```

### Why `subscribe/3` is better than `subscribe_latch/3`

The user should subscribe to a **named event source**, not to an ESC transport primitive.

Both of these should be legal:

```elixir
EtherCAT.subscribe(:sensor, :ch1)
EtherCAT.subscribe(:photoeye, :product_edge)
```

The runtime can distinguish internally whether the name resolves to:

- a cyclic PDO-backed signal
- or a named ESC latch event

The delivered message should still preserve the event kind:

```elixir
{:ethercat, :signal, :sensor, :ch1, value}
{:ethercat, :latch, :photoeye, :product_edge, timestamp_ns}
```

This is a cleaner public surface than exposing separate `subscribe_input` and `subscribe_latch` APIs.

### Why this matters

Without this, the user cannot distinguish:

- “DC configured”
- from
- “DC actually locked and healthy”

That distinction is essential.

---

## 6. Example: simple terminal I/O

This is the low-complexity case.

```elixir
EtherCAT.start(
  interface: "eth1",
  dc: %EtherCAT.DC.Config{
    cycle_ns: 1_000_000
  },
  domains: [
    %EtherCAT.Domain.Config{id: :main, cycle_time_us: 1_000}
  ],
  slaves: [
    %EtherCAT.Slave.Config{name: :coupler},
    %EtherCAT.Slave.Config{
      name: :sensor,
      driver: Example.EL1809,
      process_data: {:all, :main}
    },
    %EtherCAT.Slave.Config{
      name: :valve,
      driver: Example.EL2809,
      process_data: {:all, :main}
    }
  ]
)
```

What the user gets:

- lower jitter across the stack
- no need to think about sync outputs or latches

No `sync:` field required.

---

## 7. Example: hardware timestamping with named latches

```elixir
EtherCAT.start(
  interface: "eth1",
  dc: %EtherCAT.DC.Config{
    cycle_ns: 1_000_000,
    await_lock?: true,
    lock_policy: :recovering
  },
  domains: [
    %EtherCAT.Domain.Config{id: :main, cycle_time_us: 1_000}
  ],
  slaves: [
    %EtherCAT.Slave.Config{
      name: :photoeye,
      driver: MyLatchTerminal,
      process_data: {:all, :main},
      sync: %EtherCAT.Slave.Sync.Config{
        latches: %{
          product_edge: {0, :pos}
        }
      }
    }
  ]
)

:ok = EtherCAT.await_operational()
:ok = EtherCAT.await_dc_locked()

EtherCAT.subscribe(:photoeye, :product_edge)

receive do
  {:ethercat_latch, :photoeye, :product_edge, timestamp_ns} ->
    IO.inspect(timestamp_ns, label: "exact event time")
end
```

This is a real “advanced DC” use case that still makes sense at 1 ms.

The value is not cycle speed. The value is the **exact hardware timestamp**.

---

## 8. Example: synchronized drive + trigger

```elixir
EtherCAT.start(
  interface: "eth1",
  dc: %EtherCAT.DC.Config{
    cycle_ns: 1_000_000,
    await_lock?: true,
    lock_policy: :recovering,
    lock_threshold_ns: 100
  },
  domains: [
    %EtherCAT.Domain.Config{id: :motion, cycle_time_us: 1_000}
  ],
  slaves: [
    %EtherCAT.Slave.Config{
      name: :axis,
      driver: MyDrive,
      process_data: {:all, :motion},
      target_state: :op,
      sync: %EtherCAT.Slave.Sync.Config{
        mode: :sync0,
        sync0: %{pulse_ns: 5_000, shift_ns: 0}
      }
    },
    %EtherCAT.Slave.Config{
      name: :trigger,
      driver: MyOutputTerminal,
      process_data: {:all, :motion},
      target_state: :op,
      sync: %EtherCAT.Slave.Sync.Config{
        sync0: %{pulse_ns: 5_000, shift_ns: 0},
        sync1: %{offset_ns: 50_000}
      }
    }
  ]
)
```

Semantics:

- the system runs with a 1 ms DC cycle
- the drive uses SYNC0 as its device application timing base
- the trigger terminal emits SYNC1 at `50 us` offset from SYNC0

Important:

This does **not** mean the BEAM can schedule arbitrary new commands at `50 us`.
It means the slaves share a hardware time base, and their own DC units can act with that phase relation.

That is the right abstraction.

---

## 9. Driver contract proposal

The current `distributed_clocks/1` callback is too broad and too driver-owned.

Proposed direction:

### Keep driver responsibility for device-specific sync mode

Some slaves need device-specific CoE writes such as:

- `0x1C32`
- `0x1C33`

That remains driver territory.

### But the public sync intent belongs in `Slave.Config`

The runtime should own the generic parts:

- latch mapping
- SYNC0/SYNC1 register programming
- lock participation

The driver should only translate public sync intent into device-specific mailbox steps when needed.

### Proposed optional callback

```elixir
@callback sync_mode(config(), EtherCAT.Slave.Sync.Config.t()) ::
  [EtherCAT.Slave.Driver.mailbox_step()]
```

This is much cleaner than hiding the whole sync model inside `distributed_clocks/1`.

---

## 10. Output API under sync

There should **not** be a separate public `write_output_sync/...` API.

Writing a new output value and deciding **when the slave applies it** are different concerns.

### Proposed rule

Keep one write API:

```elixir
EtherCAT.write_output(slave_name, signal_name, value)
```

and let the slave's `sync:` configuration define **when that staged value becomes effective**
inside the slave application.

### Semantics

`write_output/3` means:

1. encode the value
2. store it into the domain image
3. send it on the next cyclic process-data frame
4. the slave applies it according to its configured sync mode

So for a slave configured with:

```elixir
sync: %EtherCAT.Slave.Sync.Config{mode: :sync0, ...}
```

the practical meaning becomes:

- "stage this as the next setpoint for the next SYNC0-driven application cycle"

That is the correct abstraction boundary.

### Why not a separate sync write API

An API like:

```elixir
EtherCAT.write_output_sync(...)
EtherCAT.write_output_at(...)
```

would imply guarantees the current runtime does not actually have:

- arbitrary nanosecond scheduling from BEAM
- future-cycle output queues in the master
- deterministic multi-cycle command buffering

None of that exists today.

### What may make sense later

If the runtime later grows explicit cycle-indexed buffering, then a future API could look like:

```elixir
EtherCAT.write_output(slave, signal, value, at: {:cycle, n})
```

But that should only exist once the master really supports:

- queued future-cycle setpoints
- cycle numbering
- deterministic replace/drop rules

Until then, `write_output/3` should remain the only write primitive.

---

## 11. Honest guarantees

The public API should document these guarantees explicitly.

### The library may guarantee

1. synchronized slave clocks when DC is enabled and locked
2. SYNC/LATCH register programming for supported slaves
3. exact latch timestamps in DC system time
4. aligned slave-side actuation/sampling relative to the DC cycle

### The library should not guarantee

1. exact BEAM-side scheduling at arbitrary nanosecond timestamps
2. sub-millisecond cyclic process-data exchange in the current runtime
3. servo-grade performance unless the DC runtime and domain cycle engine are strengthened further

---

## 12. Required runtime changes to support this API honestly

### High priority

1. fix the runtime DC datagram path
2. add DC lock detection from `0x092C`
3. add `EtherCAT.dc_status/0`
4. add `EtherCAT.await_dc_locked/1`
5. add top-level `EtherCAT.subscribe/3` and resolve named latch subscriptions through the same public surface as PDO-backed signals
6. rename domain timing to `cycle_time_us`

### Medium priority

1. replace `distributed_clocks/1` with public `sync:` config plus driver `sync_mode/2`
2. phase-align SYNC start time to the DC cycle
3. model named latches in runtime state and delivery

### Higher-complexity future work

1. CoE sync mode support for drives
2. DC drift datagram integration into the cyclic LRW frame
3. possible sub-millisecond cycle engine redesign

---

## Recommendation

Adopt this split:

### Master

```elixir
dc: %EtherCAT.DC.Config{...}
```

### Slave

```elixir
sync: %EtherCAT.Slave.Sync.Config{...}
```

### Public runtime

```elixir
EtherCAT.dc_status()
EtherCAT.await_dc_locked()
EtherCAT.reference_clock()
EtherCAT.subscribe(slave, latch_name)
```

That gives:

- correct conceptual boundaries
- named latches
- honest performance expectations
- a user-facing model that matches what applications actually care about

without forcing users to think in raw ESC registers.
