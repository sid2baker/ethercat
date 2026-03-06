# Distributed Clocks Deep Dive

## Purpose

This document explains:

1. what the current Distributed Clocks (DC) implementation does
2. which parts are aligned with the EtherCAT spec and reference masters
3. which parts are still simplified, missing, or incorrect
4. what the end user can do with DC today
5. what the public DC interface should become

The goal is to separate three different concerns that are currently easy to mix up:

1. **DC initialization**: choose a reference clock, measure delays, write offsets and delays
2. **DC runtime discipline**: keep slave clocks locked to the reference clock
3. **slave-local sync usage**: generate SYNC0/SYNC1 pulses and capture LATCH events

Those are related, but they are not the same API.

---

## Current Implementation

### 1. One-time DC initialization

`EtherCAT.DC.initialize_clocks/2` currently performs:

1. broadcast receive-time latch trigger (`0x0900`)
2. one snapshot read per slave:
   - ECAT receive time (`0x0918`)
   - port receive times (`0x0900..0x090F`)
   - speed-counter start (`0x0930`)
3. reference clock selection: first DC-capable slave in bus order
4. offset and delay planning in `EtherCAT.DC.InitPlan`
5. per-slave writes of:
   - system time offset (`0x0920`)
   - system time delay (`0x0928`)
6. PLL filter reset by writing back the latched speed-counter start (`0x0930`)

This is implemented in:
- `lib/ethercat/dc.ex`
- `lib/ethercat/dc/snapshot.ex`
- `lib/ethercat/dc/init_plan.ex`

### 2. Ongoing drift maintenance

After activation, `EtherCAT.DC` runs as its own `gen_statem` and emits a periodic drift-maintenance datagram every 10 ms.

The current code calls:

```elixir
Bus.transaction(
  bus,
  Transaction.armw(ref_station, Registers.dc_system_time()),
  drift_tick_timeout_us(period_ms)
)
```

### 3. Slave-local DC signal setup

During the checked post-`SAFEOP` step, each slave may configure local DC signal generation if:

- master startup enabled DC globally via `:dc_cycle_ns`
- the driver exports `distributed_clocks/1`

The slave then writes:

- `0x09A0` SYNC0 cycle time
- `0x09A4` SYNC1 offset/cycle
- `0x0982` pulse length
- `0x0990` start time
- `0x09A8/0x09A9` latch controls
- `0x0981` activation

If latches are configured, the slave polls latch status/timestamps during `:op`.

---

## What Is Already Good

### 1. DC initialization is structurally correct

The current init path matches the required high-level ritual:

1. latch receive times
2. read per-slave DC timing data
3. choose first DC-capable slave as reference
4. compute per-slave delay + offset
5. write delay + offset
6. reset the PLL filter state

This is the right shape and is much closer to the spec and SOEM than the rest of the DC stack.

### 2. The code cleanly separates init planning from bus I/O

`Snapshot` and `InitPlan` are pure enough to reason about. That is a good abstraction boundary.

### 3. The slave-local DC setup is placed at the right ESM point

Configuring SYNC signals after `SAFEOP` is the right direction. It avoids firing sync outputs before process-data mapping is armed.

### 4. ESC hardware latches are modeled separately from generic PDO reads

This is correct. LATCH timestamps are a hardware timestamp feature, not a generic `read_input/2` property.

---

## What Is Not Yet Spec-Conformant

These are the important gaps.

### 1. The runtime drift datagram is not integrated into the cyclic process-data frame

The spec-shaped master loop appends or prepends the DC reference-time datagram to the cyclic LRW frame. SOEM and IgH both do this in the cyclic path.

Current implementation:

- separate `EtherCAT.DC` process
- separate frame
- default period `10 ms`
- not tied to the domain cycle

That is a deliberate simplification, but it is not the canonical EtherCAT runtime model.

Impact:

- probably acceptable for discrete I/O
- weaker for tight servo/DC semantics
- runtime sync quality depends on a coarser maintenance cadence than the actual I/O cycle

### 2. The runtime drift command is likely wrong today

The current runtime tick uses:

```elixir
Transaction.armw(ref_station, Registers.dc_system_time())
```

But `Transaction.armw/2` is an **auto-increment** datagram builder whose first argument is a ring position, not a configured station address.

`ref_station` is currently a configured station address returned from DC init, not a ring position.

That means the runtime drift path is very likely addressing the wrong target.

Even apart from that, SOEM and IgH use **FRMW/FPRMW** with the reference slave's configured station address for the cyclic DC distribution path, not ARMW with a configured station address.

This is the most concrete correctness issue in the current DC runtime.

### 3. SYNC start-time programming is too naive

Current slave code computes:

```elixir
start_time = System.os_time(:nanosecond) - ethercat_epoch_offset + 100_000
```

and writes it directly.

This is simplified, but it omits two important pieces used by SOEM/IgH:

1. phase-align the first trigger to the DC timeline and cycle
2. optionally wait for sync-diff convergence before arming

Right now the start time is:

- future-relative
- not phase-aligned to the shared cycle
- not based on a fresh local/reference DC time read at programming time

For simple terminals this may still work. For a general DC interface, it is not strong enough.

### 4. No DC lock detection before Op

Current docs already acknowledge this gap:

- no poll of `0x092C`
- no `await lock` gate before OP

This means the stack can enter OP before the DC PLL has converged.

### 5. No CoE sync-mode configuration (`0x1C32` / `0x1C33`)

This is the biggest semantic gap for drives and smarter slaves.

DC initialization and SYNC pulse generation only synchronize the ESC clock domain.
Many slaves also require CoE object-dictionary configuration to tell the slave application *how* to use SYNC0/SYNC1.

Without that, the stack can be "DC-enabled" at the ESC level while the slave application is still in the wrong sync mode.

### 6. No explicit `0x0980` cyclic-unit control / assign-activate model

Current code writes `0x0981` activation and assumes default ECAT-controlled sync/latch units.

That is often fine for Beckhoff-style terminals, but it is not a complete generic model.

The ESC docs distinguish:

- `0x0980` cyclic unit control
- `0x0981` activation

IgH exposes a vendor/config driven AssignActivate word. Current code does not.

### 7. Acknowledge-mode SYNC is incomplete

Current docs already note this:

- pulse length `0` means acknowledge mode
- code does not read `0x098E` to release each pulse

So acknowledge-mode SYNC0 is not actually fully supported.

### 8. Topology handling is only linear-chain correct

`InitPlan` currently computes propagation delay using a simple chain model.
That is fine for:

- line topology
- a lot of typical terminal stacks

It is not enough for general branch/tree topologies described in the ESC datasheet.

---

## What The User Can Do Today

Today the end user can do three DC-related things.

### 1. Enable or disable DC globally

At startup:

```elixir
EtherCAT.start(
  interface: "eth1",
  dc_cycle_ns: 1_000_000
)
```

or disable it globally with `dc_cycle_ns: nil`.

This is currently the only top-level DC configuration surface in `EtherCAT.start/1`.

### 2. Request per-slave SYNC/LATCH behavior through the driver

The driver callback:

```elixir
distributed_clocks(config) ::
  %{
    sync0_pulse_ns: pos_integer(),
    optional(:sync1_cycle_ns) => pos_integer(),
    optional(:latches) => [%{latch_id: 0 | 1, edge: :pos | :neg}]
  } | nil
```

lets the driver request:

- SYNC0 pulse length
- optional SYNC1 delay
- optional latch capture edges

### 3. Consume latch events

There are two runtime consumption paths:

1. driver callback `on_latch/5`
2. low-level `EtherCAT.Slave.subscribe_latch/4`

What the user cannot do cleanly today:

- ask whether DC is active
- ask which slave is the reference clock
- ask whether clocks are locked
- wait specifically for DC lock
- inspect sync-diff values
- use a public top-level `EtherCAT.subscribe_latch/4`
- configure start-time shift or phase in a clear user API

---

## Why The Current Public Interface Is Not Clean Enough

The problem is that the public API currently exposes only one master-level DC knob:

- `:dc_cycle_ns`

while the real DC model has at least three distinct user concerns:

1. **global clock discipline**
2. **per-slave sync-output behavior**
3. **runtime observability**

The driver callback `distributed_clocks/1` also has too much conceptual weight in its name.
It does not describe "distributed clocks" in general. It only describes slave-local use of the DC domain:

- SYNC outputs
- optional latch capture

That callback is really about **sync/latch usage**, not about choosing reference clocks, offset computation, drift maintenance, or lock status.

---

## Recommended Model

### Separate the user-facing DC surface into three layers

#### A. Master-level DC configuration

This should answer:

- is DC disabled or enabled?
- what is the bus/application cycle?
- do we wait for lock before OP?
- what tolerance counts as "locked"?

A cleaner top-level shape would be something like:

```elixir
EtherCAT.start(
  interface: "eth1",
  dc: %EtherCAT.DC.Config{
    cycle_ns: 1_000_000,
    await_lock?: true,
    lock_threshold_ns: 100,
    warmup_cycles: 0
  }
)
```

Even if not every field is implemented immediately, this is a better abstraction than a lone `dc_cycle_ns`.

#### B. Slave-level sync/latch configuration

This should answer:

- should this slave emit SYNC0?
- should it emit SYNC1?
- should it capture latch edges?
- does it need a phase shift?

I would rename the driver callback from `distributed_clocks/1` to something narrower, for example:

- `sync_signals/1`
- or `dc_signals/1`

and shape it explicitly:

```elixir
%{
  sync0: %{
    pulse_ns: 10_000,
    shift_ns: 0
  },
  sync1: %{
    offset_ns: 250_000
  },
  latches: [
    %{latch_id: 0, edge: :pos}
  ]
}
```

That is a more honest abstraction than treating everything as `sync0_pulse_ns` plus optional keys.

#### C. Runtime DC observability

The user needs to be able to ask:

- is DC active?
- who is the reference clock?
- are we locked yet?
- what is the last observed sync error?

That implies a top-level public API, for example:

```elixir
EtherCAT.dc_status()
EtherCAT.await_dc_lock(timeout_ms)
EtherCAT.reference_clock()
EtherCAT.subscribe_latch(slave, latch_id, edge, pid)
```

Even if the underlying implementation evolves, these are the right user concepts.

---

## Recommended Implementation Direction

### 1. Fix the runtime drift path first

This is the first thing to fix before polishing the user API.

Spec-shaped target:

- use `FRMW`, not `ARMW` with configured station address
- ideally embed the reference-time datagram in the same frame as the cyclic LRW
- if not embedded immediately, at least make the standalone runtime datagram address-correct

### 2. Add DC runtime status

`EtherCAT.DC` should track and expose:

- `ref_station`
- active/inactive
- last tick result
- consecutive failures
- last observed sync difference per DC slave, or at least max abs diff
- locked? boolean

### 3. Add lock detection

Before final OP promotion:

- poll `0x092C`
- define a lock threshold
- gate activation on convergence or timeout

### 4. Rename the slave callback

`distributed_clocks/1` should become something narrower such as `dc_signals/1`.

This is a pre-release codebase. The naming should describe what the callback actually controls.

### 5. Add first-class top-level latch subscription

Users should not have to know about `EtherCAT.Slave.subscribe_latch/4`.

### 6. Decide whether the library wants to support servo-grade DC or only terminal-grade DC

This is the strategic question.

If the target is:

- Beckhoff terminals, discrete I/O, temperature modules, counters:
  the current model is salvageable with fixes

If the target includes:

- servo drives
- motion control
- strict cycle-phase semantics

then the library needs:

- CoE sync mode objects (`0x1C32` / `0x1C33`)
- lock detection
- better start-time alignment
- cyclic-frame-integrated reference-time distribution

---

## Bottom Line

### Spec-conform enough today for

- basic DC initialization
- line-topology propagation delay setup
- simple terminal-style SYNC0 usage
- hardware latch timestamp capture

### Not spec-complete for

- full cyclic DC runtime behavior
- generic drive/DC application sync modes
- lock-aware activation
- tree topology delay calculation
- clean user-facing observability

### Most important current issue

The runtime DC drift-maintenance path should be treated as suspect until the command/addressing model is corrected. It is the part least aligned with the reference masters.

### Recommended public API direction

Expose DC as:

1. a master-level configuration and status surface
2. a slave-level sync/latch declaration
3. a runtime lock/telemetry interface

That is the cleanest way to make DC understandable to users without leaking ESC register trivia into normal application code.
