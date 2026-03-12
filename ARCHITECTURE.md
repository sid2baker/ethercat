# EtherCAT — Architecture

## What This Is

A pure-Elixir EtherCAT master library. No NIF. No kernel module. Raw sockets only.
Targets automation workloads (discrete I/O, drives) where 1–10 ms cycle times are
sufficient and BEAM's scheduler jitter is compensated by the distributed clock layer.

---

## Module Map

```
EtherCAT.Application
│
├── EtherCAT.Master              (singleton gen_statem — bus lifecycle coordinator)
│
├── EtherCAT.SessionSupervisor   (dynamic supervisor for session-scoped runtime processes)
│   ├── EtherCAT.Bus             (bus scheduler — all frame I/O goes here)
│   │   └── EtherCAT.Bus.Link    (topology adapter selected by Bus)
│   │       ├── EtherCAT.Bus.Link.SinglePort
│   │       └── EtherCAT.Bus.Link.Redundant
│   ├── EtherCAT.DC              (gen_statem — DC maintenance + lock/status monitor)
│   └── EtherCAT.Domain          (gen_statem per domain — cyclic LRW exchange)
│
├── EtherCAT.SlaveSupervisor     (dynamic supervisor — one_for_one slave runtime children)
│   └── EtherCAT.Slave           (gen_statem per named slave — ESM lifecycle, checked PREOP setup, checked SAFEOP sync/latch setup)
│       ├── EtherCAT.Slave.ESC.SII (EEPROM reader — stateless, called from Slave.init)
│       ├── EtherCAT.Slave.Driver (behaviour contract for user drivers)
│       ├── EtherCAT.Slave.Sync.Plan (pure sync/latch register planning)
│       └── EtherCAT.Slave.ESC.Registers (ESC register address map — pure functions)
```

Optional sibling runtime (started separately, not under `EtherCAT.Application`):

```
EtherCAT.Simulator
├── EtherCAT.Simulator.Slave          (simulated slave builders + hydration from real drivers)
├── EtherCAT.Simulator.DriverAdapter  (optional simulator-side companion for real drivers)
├── EtherCAT.Simulator.Fault          (public deterministic runtime fault builder)
└── EtherCAT.Simulator.Udp            (raw UDP reply endpoint + transport-edge faults)
```

Registry: `EtherCAT.Registry` (local). Slaves register as `{:slave, name}`;
Domains register as `{:domain, id}`.

The state-machine modules `EtherCAT.Master`, `EtherCAT.Slave`,
`EtherCAT.Domain`, and `EtherCAT.DC` are intentionally small `gen_statem`
entry points. They own state
transitions, subsystem event routing, and public lifecycle/status replies.
Low-level mechanics live in helper namespaces (`EtherCAT.Master.*`,
`EtherCAT.Slave.Runtime.*`, `EtherCAT.Domain.*`, `EtherCAT.DC.*`) so the
state-machine files can be checked against the EtherCAT model without mixing in all
operational detail inline.

`EtherCAT.Simulator` follows the same boundary rule on the test/runtime side:
the public simulator process owns segment state, datagram execution, snapshots,
and deterministic fault scheduling, while profile logic and device behavior live
under `EtherCAT.Simulator.Slave.*`.

---

## Data Flow

### Startup (Master coordinates)

```
Master :discovering ──── BRD 0x0000, count stable ──── Master :awaiting_preop
  │
  ├── APWR 0x0010 × N        assign station addresses
  ├── DC.initialize_clocks/2 snapshot read + init-plan apply
  ├── SessionSupervisor      start Domain gen_statems (must exist before slaves)
  └── SlaveSupervisor        start Slave gen_statems (each auto-advances to PREOP)
        │
        Slave :init ─── SII read ─── checked mailbox SM setup ─── AL 0x02 ─── Slave :preop
              │
              explicit post-transition PREOP setup:
                mailbox_config → process-data plan → domain SM registration/FMMU writes
                → build SM-indexed signal decode map → {:slave_ready, name, :preop}
              │
              Master collects all {:slave_ready} →
              quiesce startup traffic before publishing ready
              │
              (explicit config) DC runtime start → domain cycling
              (separate DC frame carries FRMW + diagnostics) → optional DC lock wait → SafeOp
              → checked post-transition DC SYNC/latch setup → Op → Master :operational
              OR activation remains incomplete → Master :activation_blocked
              OR (dynamic startup) remain in PREOP for runtime configuration →
              Master :preop_ready
```

### Cyclic I/O (Domain owns)

```
Domain :cycling
  state_timeout :tick every whole-millisecond cycle_time_us
    build_frame  → splice outputs from ETS into zero-filled binary (iodata, no alloc)
    Bus.transaction LRW
      → raw socket send → receive → response binary
    dispatch_inputs → compare each slice against ETS → on change:
      ETS update + send {:domain_input, domain_id, key, raw} to slave pid
      Slave decodes only the signals registered for that SM via its `sm_key` index
      → driver.decode_signal/3 → notify `{:ethercat, :signal, ...}` subscribers
```

### Output path (application → bus)

```
Application
  EtherCAT.write_output(slave, signal, value)
    → Slave encodes via driver.encode_signal/3
    → Domain.write(domain_id, {slave, {:sm, sm_idx}}, binary)  ← direct :ets.update_element — no gen_statem
  next Domain LRW tick picks up the new value and writes it to the slave
```

---

## Public Lifecycle

`EtherCAT.state/0` exposes the actual `EtherCAT.Master` state machine:

- `:idle` - no session active
- `:discovering` - scanning, assigning stations, and starting session runtime
- `:awaiting_preop` - waiting for configured slaves to finish checked PREOP setup
- `:preop_ready` - bus is usable in PREOP after startup traffic has been drained
- `:deactivated` - session is live but intentionally held below OP, typically SAFEOP
- `:operational` - cyclic exchange active
- `:activation_blocked` - startup or activation reached a usable floor but not the requested target
- `:recovering` - runtime fault recovery is in progress

`await_running/1` waits for a usable state (`:preop_ready`, `:deactivated`, or
`:operational`). Before replying from startup or activation paths, the master
quiesces the bus so the first public mailbox/configuration exchange starts from
a quiet transport state.

---

## Key Design Decisions

### Bus as single serialization point

All frame I/O goes through `EtherCAT.Bus`. `Bus` is the scheduler `gen_statem`:
- `Bus.transaction/2` — reliable work. Delivery matters more than timing; reliable
  submissions may batch with other reliable submissions when the bus is already busy.
- `Bus.transaction/3` — realtime work with a staleness deadline. Realtime submissions
  are dropped if stale, always take priority over reliable backlog, and never share a
  frame with reliable traffic.

Callers define transaction boundaries with `EtherCAT.Bus.Transaction`; the bus decides
frame boundaries. This prevents multiple gen_statems from racing on the socket while
keeping frame packing policy out of slave/domain/master call sites.

`Bus` delegates topology-specific wire behavior to `EtherCAT.Bus.Link`:
- `EtherCAT.Bus.Link.SinglePort` for one interface
- `EtherCAT.Bus.Link.Redundant` for duplicated send + merged receive across two interfaces

### ETS hot path for I/O

Domain I/O bypasses the gen_statem entirely. The ETS table for each domain is `:public`
with `read_concurrency: true` / `write_concurrency: true`. Any process can read current
input values or write output values directly without a message round-trip.

### Jitter compensation via DC

BEAM's scheduler has sub-millisecond jitter. The Distributed Clock layer compensates:
ESC clocks are synchronized to sub-microsecond precision by the dedicated `DC` runtime, which
sends a realtime FRMW maintenance frame to the reference slave and periodically appends
`0x092C` diagnostics for lock detection. Per-slave
SYNC0/SYNC1/latch intent is configured through
`%EtherCAT.Slave.Config{sync: %EtherCAT.Slave.Sync.Config{...}}`. SYNC0 pulses fire from the hardware
clock, not the software scheduler — PDO exchange timing is hardware-anchored regardless of BEAM scheduling.

### gen_statem + :state_enter throughout

All gen_statems use `[:handle_event_function, :state_enter]`. Enter callbacks arm recurring
timers (domain tick, DC tick, latch poll) and emit telemetry. No enter callback may
transition state (illegal in OTP). State-deciding logic lives in the event handler that
calls `{:next_state, ...}`.

### Real driver boundary vs simulator boundary

`EtherCAT.Slave.Driver` owns runtime-facing device concerns:

- static high-level identity (`identity/0`)
- logical signal naming (`signal_model/1` or `/2`)
- signal encode/decode
- PREOP mailbox configuration and optional sync-mode object writes

Exact simulator authoring does not live in the real driver behaviour. When a
driver needs profile-specific simulator defaults, `MyDriver.Simulator` can
implement `EtherCAT.Simulator.DriverAdapter`, and
`EtherCAT.Simulator.Slave.from_driver/2` merges that simulator-side authored
configuration with the real driver's declared identity.

---

## Startup Sequence Detail

1. `Bus.start_link/1` — starts the bus scheduler and opens the selected `Bus.Link` + `Bus.Transport`
2. `DC.initialize_clocks/2` — BWR latch, read per-slave DC snapshots, build chain init plan, write offsets and delays
3. `Domain.start_link` per config — creates ETS tables, enters `:open`
4. `Slave.start_link` per config — starts SII read, checked mailbox SM setup in INIT, auto-advances to `:preop`, then runs explicit PREOP-local mailbox/process-data configuration
5. `Master` waits for all `{:slave_ready, name, :preop}` messages (30 s timeout). That message means the slave finished its local PREOP setup, not just that AL state reached PREOP.
6. Before reporting a usable startup state, the master drains late startup traffic with `Bus.quiesce/2` so the first public mailbox call or activation exchange starts cleanly.
7. If activatable slaves exist: `DC.start_link` — starts DC maintenance plus lock/status monitoring (after all slaves are in PREOP)
8. If activatable slaves exist: `Domain.start_cycling` per domain — begins self-timed LRW
9. If activatable slaves exist and `dc.await_lock? == true`: wait for the DC monitor to report `:locked`
10. If activatable slaves exist: `Slave.API.request(:safeop)` per slave — SAFEOP transition completes first, then checked ESC sync/latch configuration runs as explicit post-transition work (`0x0910/0x092C` snapshot, aligned start-time plan, `0x0980`, `0x0981`)
11. If activatable slaves exist: `Slave.API.request(:op)` per slave — full process data exchange active
12. Public startup settles in `:preop_ready`, `:operational`, or `:activation_blocked` depending on whether activation was requested and whether any activation/runtime faults remain

---

## Frame Budget (100 µs / 1 kHz example)

| Phase | Time |
|-------|------|
| BEAM scheduler + send syscall | ~50–200 µs (variable, dominant) |
| Wire propagation (10 slaves × 100 ns/hop + cable) | ~5–10 µs |
| ESC processing delay per slave | ~1 µs |
| LRW datagram overhead | ~2 µs |

At 1 ms cycle, the BEAM scheduler jitter is ~10–20% of the period. DC hardware clocks
absorb this jitter at the slave application layer — the SYNC0 pulse fires on schedule
even if the LRW frame arrives early or late.

---

## Component Entry Files

Each subsystem has a co-located module doc / source entry file:

| File | Component |
|------|-----------|
| `lib/ethercat/slave.ex` | Slave gen_statem state-machine module — ESM lifecycle, driver boundary, PREOP/SAFEOP/OP routing |
| `lib/ethercat/master.ex` | Master gen_statem state-machine module — discovery, activation, recovery, public status |
| `lib/ethercat/domain.ex` | Domain gen_statem state-machine module — cyclic LRW ownership, ETS image contract, hot-path coordination |
| `lib/ethercat/bus.ex` | Bus scheduler — transaction classes, frame dispatch, transport boundary |
| `lib/ethercat/dc.ex` | DC runtime — maintenance loop, lock/runtime status, master notifications |
| `lib/ethercat/simulator.ex` | Public simulator runtime — segment execution, snapshots, deterministic fault scheduling |
| `lib/ethercat/simulator.md` | Simulator process boundary, fault API, UDP transport split, builder surface |
| `docs/references/ethercat-esc-technology.md` | ESC hardware: FMMU, SM, DC, ESM, SII, interrupts |
| `docs/references/ethercat-esc-registers.md` | Full ESC register map (auto-extracted from datasheet) |
