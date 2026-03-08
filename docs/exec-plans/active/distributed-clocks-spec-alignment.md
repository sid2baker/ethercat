# Plan: Distributed Clocks Spec Alignment and Public API

## Status

ACTIVE

Implemented so far:

1. explicit `dc: %EtherCAT.DC.Config{}` and `cycle_time_us`
2. `dc_status/0`, `reference_clock/0`, and `await_dc_locked/1`
3. public per-slave `sync: %EtherCAT.Slave.Sync.Config{}`
4. checked SAFEOP sync/latch programming using slave DC time
5. DC lock/status monitoring in `EtherCAT.DC`
6. separate DC runtime frame ownership:
   - `EtherCAT.DC` owns the cyclic FRMW maintenance datagram
   - diagnostics (`0x092C`) ride on the DC frame itself
   - domains remain LRW/process-image owners only
7. activation-time DC lock gating through `await_lock?`
8. explicit runtime `lock_policy` handling:
   - `:advisory`
   - `:recovering`
   - `:fatal`

Supersedes the old narrow SYNC/latch plan in:

- `docs/exec-plans/active/dc-sync1-latch-complete.md`

That older plan focused on register coverage and latch plumbing. The master-wide
DC/runtime pieces are now mostly in place. The real remaining work is:

1. finish richer slave/application sync semantics
2. keep public docs and tooling aligned with the split startup/runtime DC contract
3. align the remaining sync usage details with the spec and reference masters

---

## Inputs

This plan is based on:

- `docs/design-docs/distributed-clocks-deep-dive.md`
- `docs/design-docs/distributed-clocks-public-api-proposal.md`
- EtherCAT spec summaries:
  - `docs/references/ethercat-spec/14-principles-of-dc-synchronization.md`
  - `docs/references/ethercat-spec/15-topology-and-propagation-delay-measurement.md`
  - `docs/references/ethercat-spec/16-dc-registers-and-compensation.md`
  - `docs/references/ethercat-spec/19-transitioning-to-cyclic-operation-pre-op-to-op.md`
  - `docs/references/ethercat-spec/20-the-continuous-loop.md`
- reference implementations:
  - SOEM: `docs/references/soem/src/ec_dc.c`, `ec_base.c`, `ec_main.c`
  - IgH: `docs/references/igh/master/fsm_master.c`, `fsm_slave_config.c`, `master.c`

---

## Comparison Baseline

### Current library

What exists today:

1. one-time DC init:
   - receive-time latch
   - per-slave DC snapshots
   - reference-clock election
   - offset + delay writes
   - speed-counter reset
2. separate `EtherCAT.DC` runtime worker with sync-diff lock monitoring
3. slave-local SYNC0/SYNC1/latch setup during checked post-`SAFEOP`
4. latch polling and delivery
5. `EtherCAT.DC` carries the configured-address FRMW maintenance datagram in its own cyclic frame

### SOEM

SOEM splits DC into two practical layers:

1. `ecx_configdc`
   - topology discovery
   - propagation delay computation
   - initial offset programming
2. cyclic `LRWDC` / `FRMW`
   - DC reference-time datagram is carried in the cyclic process-data frame
   - SYNC start time is based on local DC time and aligned to cycle/shift

### IgH

IgH is more staged and more complete:

1. master-level DC init and offset/delay handling
2. slave-config FSM stages:
   - write cycle registers
   - check sync quality (`0x092C`)
   - compute aligned start time
   - write start time
   - write AssignActivate (`0x0980`)
3. explicit app-time / ref-time model for phase alignment

### What we should take from both

From SOEM:

- the practical cyclic FRMW pattern
- local-time-based start-time alignment
- simplicity where possible

From IgH:

- explicit lock check before final activation
- explicit AssignActivate stage
- clean split between master-wide DC and slave-local sync usage

---

## Constraints

### Performance envelope

The current runtime should be treated as a **1 ms floor** system.

That means:

- DC remains useful for slave-side alignment and timestamps
- the API must not promise sub-cycle BEAM scheduling
- the first implementation target is correctness and observability at 1 ms

### Pre-release API rule

This library is pre-release. Breaking changes are allowed and preferred if they improve clarity.

### Scope discipline

This plan does **not** try to solve all motion-control semantics at once.

It separates:

1. generic DC infrastructure
2. generic sync/latch usage
3. device-specific drive sync mode

---

## Target API

### Master-level

```elixir
EtherCAT.start(
  interface: "eth1",
  dc: %EtherCAT.DC.Config{
    cycle_ns: 1_000_000,
    await_lock?: true,
    lock_policy: :recovering,
    lock_threshold_ns: 100,
    lock_timeout_ms: 5_000,
    warmup_cycles: 0
  },
  domains: [
    %EtherCAT.Domain.Config{id: :main, cycle_time_us: 1_000}
  ],
  slaves: [...]
)
```

### Slave-level

```elixir
%EtherCAT.Slave.Config{
  name: :axis,
  driver: MyDrive,
  process_data: {:all, :main},
  target_state: :op,
  sync: %EtherCAT.Slave.Sync.Config{
    mode: :sync0,
    sync0: %{pulse_ns: 5_000, shift_ns: 0},
    sync1: nil,
    latches: %{}
  }
}
```

### Runtime API

```elixir
EtherCAT.dc_status()
EtherCAT.reference_clock()
EtherCAT.await_dc_locked(timeout_ms \\ 5_000)
EtherCAT.subscribe(slave_name, signal_or_latch_name, pid \\ self())
EtherCAT.write_output(slave_name, signal_name, value)
```

Important:

- keep `write_output/3`
- do **not** add a sync-specific write API
- `sync:` determines when the slave applies staged outputs

---

## Historical Landed Phases

Phases 1 through 4 are already implemented. They remain here as rationale for
how the current DC architecture was reached.

## Phase 1 — Correct the runtime DC datagram path

### Goal

Fix the most concrete correctness issue first.

### Why first

Current runtime drift maintenance appears to use the wrong datagram/addressing model:

- `Transaction.armw(ref_station, Registers.dc_system_time())`

`armw/2` is auto-increment addressed, but `ref_station` is a configured station address.

### Changes

1. replace the current runtime drift datagram with a configured-address DC datagram
2. use `FRMW` semantics, not `ARMW`
3. keep it as a standalone DC-owned realtime frame
4. make the addressing and intent explicit in code and docs

### Files

- `lib/ethercat/dc.ex`
- `lib/ethercat/bus/transaction.ex`
- `lib/ethercat/slave/registers.ex`
- tests under `test/ethercat/dc/`

### Acceptance

1. runtime DC no longer uses auto-increment addressing with a configured station
2. the FRMW maintenance datagram is now owned by `EtherCAT.DC`
3. tests cover datagram selection and addressing

---

## Phase 2 — Introduce explicit DC config and microsecond domain timing

### Goal

Replace ambiguous timing knobs with honest configuration objects.

### Changes

1. replace top-level `:dc_cycle_ns` with `dc: %EtherCAT.DC.Config{}`
2. replace domain `period_ms` with `cycle_time_us`
3. keep runtime validation at `cycle_time_us >= 1_000` for now
4. update all call sites, examples, tests, and docs

### Files

- `lib/ethercat.ex`
- `lib/ethercat/master/config.ex`
- `lib/ethercat/domain/config.ex`
- `lib/ethercat/domain.ex`
- examples, tests, docs

### Acceptance

1. no public `dc_cycle_ns`
2. no public `period_ms`
3. all examples use `dc: %EtherCAT.DC.Config{...}` and `cycle_time_us`

---

## Phase 3 — Add DC runtime status and lock API

### Goal

Make DC observable.

### Changes

1. add `%EtherCAT.DC.Status{}`
2. add:
   - `EtherCAT.dc_status/0`
   - `EtherCAT.reference_clock/0`
   - `EtherCAT.await_dc_locked/1`
3. extend `EtherCAT.DC` runtime state to track:
   - `enabled?`
   - `ref_station`
   - `locked?`
   - last sync-diff check
   - max observed abs diff
   - consecutive runtime failures
4. add telemetry for lock state changes and sync-diff observations

### Files

- `lib/ethercat/dc.ex`
- `lib/ethercat.ex`
- `lib/ethercat/telemetry.ex`
- tests

### Acceptance

1. user can ask whether DC is active and locked
2. user can ask which slave is the reference clock
3. `await_dc_locked/1` has defined timeout/error semantics

---

## Phase 4 — Add DC lock detection before OP

### Goal

Do not claim the system is operational before clocks are actually synchronized.

### Changes

1. poll `Registers.dc_system_time_diff()` (`0x092C`) during activation
2. use `lock_threshold_ns` and `lock_timeout_ms` from `EtherCAT.DC.Config`
3. gate final OP completion on lock convergence when `await_lock? == true`
4. expose failures clearly:
   - `{:error, {:dc_lock_timeout, details}}`

### Design note

This should happen after runtime DC maintenance has started, because lock depends on ongoing reference-time distribution.

### Files

- `lib/ethercat/master.ex`
- `lib/ethercat/dc.ex`
- tests

### Acceptance

1. OP completion can wait for DC lock
2. lock timeout is reported explicitly
3. disabled-DC startup remains clean and does not go through lock logic

---

## Phase 5 — Replace driver-owned `distributed_clocks/1` with public `sync:` config

### Goal

Move generic sync/latch intent out of the driver behaviour and into `Slave.Config`.

### Changes

1. add `%EtherCAT.Slave.Sync.Config{}`
2. add `:sync` to `%EtherCAT.Slave.Config{}`
3. remove `distributed_clocks/1` from the public driver contract
4. keep device-specific sync mode translation in a new optional driver callback:

```elixir
@callback sync_mode(config(), EtherCAT.Slave.Sync.Config.t()) ::
  [mailbox_step()]
```

### Why

Drivers should own device-specific CoE mapping, not the generic public sync model.

### Files

- `lib/ethercat/slave/config.ex`
- `lib/ethercat/slave/sync/config.ex`
- `lib/ethercat/slave/driver.ex`
- `lib/ethercat/slave.ex`
- examples/tests/docs

### Acceptance

1. public slave config uses `sync: ...`
2. generic latch and SYNC definitions are no longer driver-owned
3. drivers can still translate sync intent into mailbox writes when needed

---

## Phase 6 — Named latches and unified subscription surface

### Goal

Use one public subscription API for both process-data signals and latch events.

### Changes

1. add named latch mapping in `EtherCAT.Slave.Sync.Config`:

```elixir
latches: %{
  product_edge: {0, :pos}
}
```

2. replace top-level `subscribe_input`-style public thinking with:

```elixir
EtherCAT.subscribe(slave, name, pid \\ self())
```

3. resolve `name` against:
   - registered process-data signals
   - named latches

4. preserve distinct message shapes:

```elixir
{:ethercat, :signal, slave, name, value}
{:ethercat, :latch, slave, name, timestamp_ns}
```

### Files

- `lib/ethercat.ex`
- `lib/ethercat/slave.ex`
- possibly `lib/ethercat/domain.ex` call-site docs
- tests/docs/examples

### Acceptance

1. user subscribes by semantic name, not by “input vs latch” transport kind
2. named latch delivery works through the same public API as normal signals

---

## Phase 7 — Improve slave sync programming to match SOEM/IgH more closely

### Goal

Make slave-local sync setup robust and spec-shaped.

### Changes

1. add `Registers.dc_cyclic_unit_control()` / `dc_cyclic_unit_control(code)` for `0x0980`
2. optionally add `Registers.dc_sync0_status()` for acknowledge-mode support
3. change slave sync programming flow to:
   - clear/deactivate current sync activation
   - write cycle parameters
   - optionally read sync-diff and wait for reasonable convergence
   - read current DC local/reference time
   - compute phase-aligned start time using cycle and shift
   - write start time
   - write `0x0980` cyclic-unit control / assign-activate
   - write `0x0981` activation
4. keep activation as the last write in the final transaction stage

### Comparison target

- SOEM for simple local-time-aligned start
- IgH for staged check/start/assign flow

### Files

- `lib/ethercat/slave/registers.ex`
- `lib/ethercat/slave.ex`
- tests/docs

### Acceptance

1. start time is no longer host-wall-clock-plus-margin only
2. `shift_ns` participates in start-time alignment
3. `0x0980` is part of the explicit sync model

---

## Phase 8 — Acknowledge-mode SYNC support

### Goal

Support `pulse_ns == 0` honestly.

### Changes

1. define SYNC acknowledge-mode behavior explicitly
2. add the necessary `0x098E` read/ack path
3. expose whether acknowledge mode is supported in docs and config validation

### Acceptance

1. `pulse_ns == 0` is either fully supported or rejected explicitly
2. no silent partial support

---

## Phase 9 — Device-specific drive sync mode support

### Goal

Support slaves that need CoE sync mode objects in addition to ESC DC setup.

### Changes

1. use the new driver `sync_mode/2` callback for device-specific mailbox steps
2. support common object-dictionary sync configuration:
   - `0x1C32`
   - `0x1C33`
3. document clearly that:
   - generic `sync:` config programs ESC sync units
   - driver `sync_mode/2` programs the slave application sync mode

### Acceptance

1. drive-style slaves can express sync mode cleanly
2. the public API stays generic and does not expose raw object indices

---

## Phase 10 — Optional future: integrate DC reference-time datagram into the cyclic frame

### Goal

Move from “correct standalone DC tick” to the canonical cyclic integration model.

### Changes

1. decide whether DC maintenance belongs in `Domain` or `Bus`
2. append/prepend FRMW datagram to the cyclic LRW frame
3. remove the separate `EtherCAT.DC` ticker if the integrated model fully replaces it

### Why last

This is architecturally larger than the other fixes. It should only happen after:

1. the public API shape is stable
2. lock/status semantics are in place
3. current runtime correctness issues are fixed

---

## Testing Strategy

### Unit tests

1. DC config validation
2. domain `cycle_time_us` validation
3. runtime drift datagram selection/addressing
4. lock-detection state transitions
5. runtime lock-policy transitions
6. sync config normalization
7. latch-name resolution
8. start-time alignment math
9. acknowledge-mode behavior

### Integration tests

1. DC init with DC-capable and non-DC-capable snapshots
2. activation with and without `await_lock?`
3. runtime lock loss under each `lock_policy`
4. latch delivery through unified `subscribe/3`
5. drive-like `sync_mode/2` mailbox planning

### Hardware validation

1. simple Beckhoff terminal stack at 1 ms
2. named latch event timestamping on real hardware
3. DC lock convergence observation under load
4. at least one sync-sensitive slave requiring CoE sync mode objects

---

## Acceptance Criteria

1. runtime DC datagram path is address-correct and FRMW-shaped
2. public API uses:
   - `dc: %EtherCAT.DC.Config{}`
   - `sync: %EtherCAT.Slave.Sync.Config{}`
   - `cycle_time_us`
3. public runtime exposes:
   - `dc_status/0`
   - `reference_clock/0`
   - `await_dc_locked/1`
   - unified `subscribe/3`
4. `write_output/3` remains the only write primitive
5. lock-aware activation is implemented
6. named latches work through the normal subscription surface
7. acknowledge-mode SYNC is either supported correctly or rejected explicitly
8. docs clearly distinguish:
   - master-wide DC infrastructure
   - slave-local sync usage
   - device-specific sync mode

---

## Recommendation

Implement phases 1 through 4 first.

Reason:

1. they fix correctness
2. they provide observability
3. they establish the real DC contract before API cleanup gets wider

Then implement phases 5 through 7 as the public API cleanup and sync-model alignment layer.

Phase 10 should stay optional until the simpler corrected runtime is proven on hardware.
