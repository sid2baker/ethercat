# EtherCAT — Architecture

## What This Is

A pure-Elixir EtherCAT master library. No NIF. No kernel module.

Real hardware runs over raw sockets. UDP exists as a simulator and integration
transport boundary, not as a claim that the production master speaks UDP on a
real ring.

The target is still automation workloads (discrete I/O, drives) where 1–10 ms
cycle times are sufficient and BEAM scheduler jitter is compensated by the
distributed clock layer.

---

## Module Map

```
Host application supervisor
└── EtherCAT.Runtime
    │
    ├── EtherCAT                    (protocol status/sample/notification/read/write API)
    ├── EtherCAT.Session            (opaque master pid + session generation)
    ├── EtherCAT.Backend            (normalized backend description)
    ├── EtherCAT.Scan               (one-shot observational topology scan)
    ├── EtherCAT.Provisioning       (advanced PREOP/configuration/SDO API)
    ├── EtherCAT.Diagnostics        (advanced inspection and runtime visibility API)
    ├── EtherCAT.Driver             (public driver behaviour for extension authors)
    ├── EtherCAT.Signals                (signal and latch subscriptions)
    │
    ├── EtherCAT.Master             (singleton gen_statem — bus lifecycle coordinator)
    │
    ├── EtherCAT.SessionSupervisor  (dynamic supervisor for session-scoped runtime processes)
    │   ├── EtherCAT.Bus            (bus scheduler — all frame I/O goes here)
    │   │   ├── EtherCAT.Bus.Link.Single
    │   │   ├── EtherCAT.Bus.Link.Redundant
    │   │   ├── EtherCAT.Bus.Link.RedundantMerge
    │   │   └── EtherCAT.Bus.Transport.*      (raw/UDP transport boundary)
    │   ├── EtherCAT.DC             (gen_statem — DC maintenance + lock/status monitor)
    │   └── EtherCAT.Domain         (gen_statem per domain — cyclic LRW exchange)
    │
    ├── EtherCAT.SlaveSupervisor    (dynamic supervisor — one_for_one slave runtime children)
    │   └── EtherCAT.Slave          (gen_statem per named slave — ESM lifecycle, checked PREOP setup, checked SAFEOP sync/latch setup)
    │       ├── EtherCAT.Slave.ESC.SII (EEPROM reader — stateless, called from Slave.init)
    │       ├── EtherCAT.Driver (behaviour contract for user drivers)
    │       ├── EtherCAT.Slave.Sync.Plan (pure sync/latch register planning)
    │       └── EtherCAT.Slave.ESC.Registers (ESC register address map — pure functions)
```

`Master.FSM` owns lifecycle decisions and transition replies. `Master.Recovery`
performs recovery operations and returns their results and updated master data;
it does not select state-machine transitions. `Master.Diagnostics` collects live
observations, and `Master.Status` projects explicitly supplied observations into
the public status struct. The master captures a configuration snapshot and exact
worker PIDs without making live process calls. Diagnostic callers gather those
observations under a shared one-second budget and revalidate the session generation
before returning; timeout, exit, and invalid-reply failures stay explicit.
Worker lifecycle messages carry the originating PID and are validated against
current registered workers and session configuration before entering transition
logic. Unwrapped messages and stale workers cannot mutate the new session.
An idle master has no desired runtime target; active sessions set one validated target (`:preop`, `:safeop`, or `:op`).

Session process resolution validates the generation at the master, then looks up
only the requested configured slave or domain. Descriptions and inventory read
configuration directly, with lightweight identity and tracked-fault metadata;
they do not construct diagnostic reports or query bus, DC, or domain processes.

Each bus link owns dispatch and send-result handling. `Bus.Link` shares queue
selection, batching, datagram index assignment, and reply primitives. `Domain`
owns its initialization and defaults; `Domain.Image` and `Domain.Layout` retain
storage and layout responsibilities.

Optional sibling runtime (started separately, not under `EtherCAT.Runtime`):

```
EtherCAT.Simulator
├── EtherCAT.Simulator.Slave                (simulated slave builders + hydration from real drivers)
├── EtherCAT.Simulator.Adapter              (optional simulator-side companion for real drivers)
├── EtherCAT.Simulator.Fault                (public deterministic runtime fault builder)
└── EtherCAT.Simulator.Transport
    ├── EtherCAT.Simulator.Transport.Udp
    │   └── EtherCAT.Simulator.Transport.Udp.Fault
    └── EtherCAT.Simulator.Transport.Raw
        ├── EtherCAT.Simulator.Transport.Raw.Fault
        └── EtherCAT.Simulator.Transport.Raw.Endpoint   (internal worker)
```

Registry: `EtherCAT.Registry` (local). Slaves register as `{:slave, name}`;
Domains register as `{:domain, id}`.

The normal runtime surface is `EtherCAT`. `EtherCAT.Provisioning`,
`EtherCAT.Diagnostics`, `EtherCAT.Signals`, and `EtherCAT.Driver` are specialist
public modules. `EtherCAT.Master`, `EtherCAT.Slave`, `EtherCAT.Domain`, and
`EtherCAT.DC` are the core runtime processes behind that surface. `Domain` and
`DC` own their small `gen_statem` callbacks directly; larger lifecycle
boundaries such as `Master` and `Slave` keep dedicated FSM modules so their
state transitions can still be audited separately from operational helpers.
Low-level mechanics live in helper namespaces (`EtherCAT.Master.*`,
`EtherCAT.Slave.Runtime.*`, `EtherCAT.Domain.*`, `EtherCAT.DC.*`) only where
they carry real protocol or lifecycle weight.

`EtherCAT.Runtime` is the supported root boundary. Host applications own its
lifecycle. `EtherCAT.start/1` opens the singleton session and returns an opaque
`EtherCAT.Session` containing the master pid and session generation. Every
runtime, provisioning, diagnostic, signal subscription, and capture operation
requires that session. Calls are validated inside the master serialization
boundary, so a stopped session cannot target a later replacement session.

`EtherCAT.Simulator` follows the same boundary rule on the test/runtime side:
the public simulator process owns segment state, datagram execution,
`status/0`, and deterministic fault scheduling, while profile logic and device
behavior live under `EtherCAT.Simulator.Slave.*`.

The top-level runtime roles are now explicit:

- `EtherCAT.Backend` describes how a runtime attaches to a transport boundary
- `EtherCAT.Scan.scan/1` reports observed topology only
- `EtherCAT.Diagnostics.master_status/1` reports session controller/runtime state
- `EtherCAT.Simulator.status/0` reports simulator/runtime state

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

### Cyclic I/O (runtime + driver)

```
Domain :cycling
  state_timeout :tick every whole-millisecond cycle_time_us
    build_frame  → splice outputs from ETS into zero-filled binary (iodata, no alloc)
    Bus.transaction LRW
      → raw socket send → receive → response binary
    dispatch_inputs → compare each slice against ETS → on change:
      ETS update + send the coherent per-slave domain response image to the slave pid
      Slave computes changed signal names from changed SM slices
      → decodes the complete input image for that slave and domain
      → retains and publishes %EtherCAT.Sample{}
      → reuses the same decoded values for raw signal subscribers
```

A sample is coherent only within its domain cycle. A slave split across domains
produces independent samples; the runtime does not imply cross-domain
consistency.

### Protocol status and notifications

`EtherCAT.subscribe/2` installs the subscriber and reads the current
`EtherCAT.Slave.Status` plus retained samples at one slave-process serialization
boundary, returning `{:ok, ref, status, samples}`. The same process subsequently
sends `{:ethercat, ref, payload}` containing samples and `EtherCAT.Notification`
values, preserving their local ordering. `EtherCAT.unsubscribe/3` cancels that
registration. Push delivery has no backpressure; consumers that only need the
latest values can poll `EtherCAT.samples/2`.

Slave AL/runtime transitions produce `:slave_state_changed` notifications.
Domains fan lifecycle and cycle-health transitions to each attached slave;
slave runtimes retain those `EtherCAT.Domain.Status` values and publish
`:domain_status_changed` notifications. These are protocol/runtime facts for a
higher-level adapter to interpret, not machine availability or semantic events.

### Protocol write path (application → bus)

```
Application
  EtherCAT.write(session, slave, signal, value)
    → driver.encode_signal/3
    → runtime stages the encoded value through Domain.write/3
  next Domain LRW tick picks up the value and writes it to the slave
```

`EtherCAT.Signals.*` remains available for signal and latch subscriptions used by specialist
diagnostics and tooling.

---

## Public Lifecycle

`EtherCAT.state/1` exposes the actual `EtherCAT.Master` state machine for one session:

- `:discovering` - scanning, assigning stations, and starting session runtime
- `:awaiting_preop` - waiting for configured slaves to finish checked PREOP setup
- `:preop_ready` - bus is usable in PREOP after startup traffic has been drained
- `:deactivated` - session is live but intentionally held below OP, typically SAFEOP
- `:operational` - cyclic exchange active
- `:activation_blocked` - startup or activation reached a usable floor but not the requested target
- `:recovering` - runtime fault recovery is in progress

`await_ready/1` waits for a usable state (`:preop_ready`, `:deactivated`, or
`:operational`). Before replying from startup or activation paths, the master
quiesces the bus so the first public mailbox/configuration exchange starts from
a quiet transport state.

Even while the session is intentionally held in PREOP or SAFEOP, slave health
polling remains active. Disconnects and lower-than-held AL-state regressions
still surface as runtime faults instead of leaving those held states stale.

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

`Bus` delegates exchange execution to `EtherCAT.Bus.Link.*`:
- `EtherCAT.Bus.Link.Single` for one interface
- `EtherCAT.Bus.Link.Redundant` for duplicated send + observed redundant-path interpretation

### Bus execution layers

The current design keeps three concerns separate:

- queueing and caller reply policy
- socket/transport I/O
- topology inference and cable-fault interpretation

The current design splits those concerns more cleanly:

- `EtherCAT.Bus` remains the single scheduler and caller-facing serialization point
- `EtherCAT.Bus.Transport.*` stays the low-level socket boundary (`RawSocket`, `UdpSocket`)
- `EtherCAT.Bus.Link.*` executes one EtherCAT exchange over one or more transports
- `EtherCAT.Bus.Link` provides the shared batching, queue, and caller-reply helpers
- `EtherCAT.Bus.Link.RedundantMerge` is the pure merge helper for split redundant replies
- `Bus.info/1` exposes the active link's queue, in-flight exchange, and topology/health state directly

The important design change is that topology is derived from observed frame
returns, not controlled from OS carrier events.

Target module shape:

```
EtherCAT.Bus
├── EtherCAT.Bus.Result
├── EtherCAT.Bus.Link
│   ├── EtherCAT.Bus.Link.Single
│   └── EtherCAT.Bus.Link.Redundant
├── EtherCAT.Bus.Link.RedundantMerge
└── EtherCAT.Bus.Transport
    ├── EtherCAT.Bus.Transport.RawSocket
    └── EtherCAT.Bus.Transport.UdpSocket
```

Conceptual boundaries:

- `Transport` — one socket/device transport, no topology ownership
- `Link.Single` / `Link.Redundant` — execute one exchange over one or more transports
- `RedundantMerge` — pure per-exchange truth (`path_shape`, merged datagrams, total WKC)
- `Bus.info/1` — current public runtime view (type, topology, health, queues, exchange)

Per-exchange `path_shape` values from `EtherCAT.Bus.Link.RedundantMerge`:

- `:single`
- `:full_redundancy`
- `:primary_only`
- `:secondary_only`
- `:complementary_partials`
- `:no_valid_return`
- `:invalid`

Public `topology` values from `Bus.info/1` today:

- `:single`
- `:redundant`
- `:degraded_primary_leg`
- `:degraded_secondary_leg`
- `:offline`

Redundant topology should degrade quickly and recover conservatively. A strong
send/receive failure can change public topology immediately, while promotion
back to `:redundant` should require observed healthy traffic rather than OS
carrier state alone.

OS link state is intentionally outside the bus runtime model. Interface status
is a separate diagnostic concern and is not part of the correctness path for
bus exchange execution.

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

`EtherCAT.Driver` owns protocol/device concerns only:

- device identity
- logical signal naming and PDO layout (`signal_model/2`)
- static signal metadata
- signal encode/decode

Machine-state projection, semantic command planning, and machine events belong
above EtherCAT in a separate semantic integration layer.

Specialist driver behaviours hang off the core:

- `EtherCAT.Driver.Provisioning` for PREOP mailbox configuration and sync-update object writes
- `EtherCAT.Driver.Latch` for optional DC latch hooks
- `EtherCAT.Simulator.Adapter` for simulator-side authored definitions

Exact simulator authoring does not live in the real driver behaviour. Drivers
may optionally expose `identity/0` directly on `EtherCAT.Driver`. When a
driver needs profile-specific simulator defaults, `MyDriver.Simulator` can
implement `EtherCAT.Simulator.Adapter`, and
`EtherCAT.Simulator.Slave.from_driver/2` merges that simulator-side authored
configuration with the real driver's declared identity.

---

## Startup Sequence Detail

1. `Bus.start_link/1` — starts the bus scheduler and opens the selected `Bus.Link.*` over one or two transports
2. `DC.initialize_clocks/2` — BWR latch, read per-slave DC snapshots, build chain init plan, write offsets and delays
3. `Domain.start_link` per config — creates ETS tables, enters `:open`
4. `Slave.start_link` per config — starts SII read, checked mailbox SM setup in INIT, auto-advances to `:preop`, then runs explicit PREOP-local mailbox/process-data configuration
5. `Master` waits for all `{:slave_ready, name, :preop}` messages (30 s timeout). That message means the slave finished its local PREOP setup, not just that AL state reached PREOP.
6. Before reporting a usable startup state, the master drains late startup traffic with `Bus.quiesce/2` so the first public mailbox call or activation exchange starts cleanly.
7. If activatable slaves exist: `DC.start_link` — starts DC maintenance plus lock/status monitoring (after all slaves are in PREOP)
8. If activatable slaves exist: `Domain.start_cycling` per domain — begins self-timed LRW
9. If activatable slaves exist and `dc.await_lock? == true`: wait for the DC monitor to report `:locked`
10. If activatable slaves exist: `Slave.request(:safeop)` per slave — SAFEOP transition completes first, then checked ESC sync/latch configuration runs as explicit post-transition work (`0x0910/0x092C` snapshot, aligned start-time plan, `0x0980`, `0x0981`)
11. If activatable slaves exist: `Slave.request(:op)` per slave — full process data exchange active
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

Each subsystem has a co-located source or source-adjacent entry file:

| File | Component |
|------|-----------|
| `lib/ethercat/slave.ex` | Slave gen_statem state-machine module — ESM lifecycle, driver boundary, PREOP/SAFEOP/OP routing |
| `lib/ethercat/master.ex` | Master gen_statem state-machine module — discovery, activation, recovery, public status |
| `lib/ethercat/domain.ex` | Domain gen_statem state-machine module — cyclic LRW ownership, ETS image contract, hot-path coordination |
| `lib/ethercat/bus.ex` | Bus scheduler — transaction classes, frame dispatch, transport boundary |
| `lib/ethercat/dc.ex` | DC runtime — maintenance loop, lock/runtime status, master notifications |
| `lib/ethercat/simulator.ex` | Public simulator runtime — segment execution, snapshots, deterministic fault scheduling |
| `lib/ethercat/simulator.md` | Simulator process boundary, transport split, and fault-builder surface |

Deeper ESC hardware and register background should live in local helper material
outside the tracked repo, not in project-owned documentation.
