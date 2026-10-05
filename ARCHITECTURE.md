# EtherCAT architecture

EtherCAT is an experimental pure-Elixir EtherCAT master: no NIF or custom kernel
module. Physical rings use raw Ethernet sockets. UDP is a simulator/integration
transport, not a claim that ordinary EtherCAT slaves accept UDP.

Start with the [README](README.md) for setup and the public module docs for API
contracts. This document explains ownership, sequencing, and data flow.

## Public boundaries

| Module | Responsibility |
|--------|----------------|
| `EtherCAT` | Session lifecycle, protocol status, samples, descriptions, subscriptions, reads and writes |
| `EtherCAT.Runtime` | Host-owned singleton supervision root |
| `EtherCAT.Session` | Opaque master PID and generation identifying one session |
| `EtherCAT.Backend` | Raw, redundant raw, or UDP transport description |
| `EtherCAT.Scan` | One-shot discovery; assigns station addresses, so it is not passive |
| `EtherCAT.Provisioning` | PREOP configuration, activation/deactivation, SDO traffic |
| `EtherCAT.Diagnostics` | Live master, slave, domain, and DC inspection |
| `EtherCAT.Signals` | Specialist signal/latch subscriptions |
| `EtherCAT.Driver` | Device signal mappings, codecs, optional identity and static metadata |
| `EtherCAT.Simulator` | Separately started virtual slave segment and fault scheduling |

These are API roles, not separate processes. Machine-state projection, semantic
commands, and machine events belong in a higher-level integration, not in the
protocol driver.

## Supervision and session ownership

```text
Host application supervisor
└── EtherCAT.Runtime                     (one per BEAM node; one_for_all)
    ├── EtherCAT.Registry                (local slave/domain registry)
    ├── EtherCAT.SlaveSupervisor          (dynamic, one_for_one)
    │   └── EtherCAT.Slave × configured slave
    ├── EtherCAT.SessionSupervisor       (dynamic, one_for_one)
    │   ├── EtherCAT.Bus                 (single or redundant link process)
    │   ├── EtherCAT.Domain × domain     (cyclic LRW and process image)
    │   └── EtherCAT.DC                  (when DC runtime is active)
    └── EtherCAT.Master                  (singleton lifecycle coordinator)
```

The host starts `EtherCAT.Runtime`; the package does not autostart it as an OTP
application. `EtherCAT.start/1` opens a session inside that tree. `EtherCAT.stop/1`
ends the session, not the host-owned supervisor.

Normal runtime, provisioning, diagnostic, subscription, and capture calls carry
an `EtherCAT.Session`. The master validates its generation before resolving
workers. Stopped or replaced sessions cannot silently address new workers.
Low-level bus/domain process APIs also exist for internal work and tests; they
are not substitutes for the session-bound application API.

Slaves register as `{:slave, name}` and domains as `{:domain, id}`. Worker lifecycle
messages include their originating PID; the master checks it against the current
workers and configuration before applying a transition.

`Master.FSM` owns lifecycle decisions. `Master.Recovery` performs recovery work
and returns results, rather than selecting state-machine transitions. Diagnostic
callers collect live observations under a shared one-second budget and revalidate
the session afterward. Timeouts, exits, and invalid replies remain explicit.
Descriptions and inventory read configuration without constructing live diagnostic
reports or querying bus, domain, and DC processes.

## Startup and lifecycle

```text
EtherCAT.start(options) → returns session; startup continues asynchronously
  Master :discovering
    count stable slaves → assign station addresses → optional DC initialization
    start domains in :open → start slaves in physical configuration order
  Master :awaiting_preop
    each slave: INIT → SII read → checked mailbox SM setup → PREOP
      → driver mailbox configuration → checked process-data plan
      → domain registration and FMMU programming → report PREOP-ready
    master drains startup traffic with Bus.quiesce
  no activation requested → :preop_ready
  activation requested
    → optional DC runtime → domain cycling → optional DC lock wait
    → SAFEOP → checked slave-local SYNC/latch setup → OP
    → :operational, or :activation_blocked if the target is not reached
```

The absence of an explicit slave list means discovery/provisioning, not automatic
cyclic configuration. Discovered devices are named `:coupler`, `:slave_1`, … by
position and held in PREOP. Those names do not identify device types. Explicit
`EtherCAT.Slave.Config` entries default to `target_state: :op`; their order determines
which physical devices they configure. Driver identity is not automatic device
compatibility enforcement.

`EtherCAT.state/1` exposes:

- `:discovering` — scanning and preparing session workers
- `:awaiting_preop` — waiting for checked slave-local PREOP setup
- `:preop_ready` — usable PREOP session, not cyclic operation
- `:deactivated` — live session intentionally held below OP, normally SAFEOP
- `:operational` — activated runtime; non-critical slave-local faults may still exist
- `:activation_blocked` — requested target not fully reached
- `:recovering` — critical runtime fault recovery

`await_ready/2` accepts `:preop_ready`, `:deactivated`, or `:operational`.
`await_operational/2` waits for activation. Neither promises that every signal has
already produced its first sample or that a previously observed state remains
healthy forever.

Health polling is deliberately suppressed during an initial all-PREOP provisioning
session. Activation restores configured polling, including for slaves intentionally
left in PREOP. Runtime-held PREOP/SAFEOP states can then detect disconnects and
lower-state regressions. `health_poll_ms: nil` explicitly disables slave polling;
cyclic domain faults are a separate source of runtime health.

Deactivation stops cycling and retreats activatable slaves to SAFEOP or PREOP.
Reconfiguration requires PREOP, not the default SAFEOP hold. Fault recovery aims
at the desired runtime target; it must not promote a deliberately held slave to OP.

## Cyclic data flow

```text
Application: EtherCAT.write(session, slave, signal, value)
  → slave invokes driver.encode_signal/3
  → runtime validates width/padding and stages output in domain ETS
  → next domain tick builds LRW image from staged outputs
  → Bus schedules and executes exchange
  → domain validates transport reply and WKC
  → valid changed input slices update ETS
  → slave receives a coherent input image for its domain
  → driver decodes signals; slave retains/publishes EtherCAT.Sample
```

Domain periods are whole milliseconds expressed as `cycle_time_us`. The domain
owns timing, validity, and its ETS-backed process image. Low-level image reads and
writes bypass the domain mailbox; public signal calls still pass through the slave
for codec and session-bound access. ETS is an implementation detail, not the
application integration contract.

Input publication is change-driven, not a guarantee of one message per cycle.
The retained sample describes one slave in one domain cycle; different domains
have independent consistency boundaries. `Sample.inputs` contains successfully
decoded values and `Sample.errors` contains failures, without substituting old
values. `observed_at` is host monotonic microseconds, not wall time or DC time.
Use current status/domain diagnostics as well as retained data to assess health.

A successful write means staging, not device acknowledgement or physical actuation.
A later write may replace the staged value before transmission. Faults and stopped
cycling can prevent staged data from reaching the device.

### Subscriptions and notifications

`EtherCAT.subscribe/3` registers a subscriber and obtains current status/samples
at one slave-process serialization boundary. It returns
`{:ok, ref, status, samples}`. Later `{:ethercat, ref, payload}` messages contain
samples or `EtherCAT.Notification` values, ordered by that slave process.

Notifications report slave state and attached-domain lifecycle/health changes;
they do not imply machine availability or command completion. Push delivery has
no backpressure. Poll `samples/2` when only the latest observation is needed.
Subscriber or slave exit cancels a registration; `unsubscribe/3` does not remove
messages already in the subscriber's mailbox.

## Bus scheduling and transport

All frame I/O passes through the bus scheduler. Callers define transaction
boundaries with `EtherCAT.Bus.Transaction`; the bus chooses frame boundaries.

- Reliable transactions do not expire while queued and may batch together.
  They can still fail or time out after dispatch.
- Realtime transactions have a maximum queued age, take priority over reliable
  work, and never share a frame with reliable transactions. This is scheduling
  policy, not a hard real-time guarantee.

```text
EtherCAT.Bus                         caller-facing scheduler API
├── Bus.Link                         queues, batching, indices, replies
├── Bus.Link.Single                  one-transport exchange execution
├── Bus.Link.Redundant               dual-raw exchange execution
├── Bus.Link.RedundantMerge          pure reply merging/classification
└── Bus.Transport.*                  raw/UDP socket boundary
```

The active link is the bus process, not a child process behind a second scheduler.
Link modules own dispatch and send-result handling. Redundant exchange handling
uses observed frame returns and open/send failures; OS carrier state is not the
correctness model. `Bus.info/1` exposes topology, transport health, queues, and
in-flight state. A degraded topology and a valid merged exchange are distinct
observations. See `EtherCAT.Bus.Link.Redundant` for authoritative-reply and timeout
rules, rather than inferring health from carrier alone.

## Distributed Clocks and timing limits

DC initialization selects the first DC-capable station, measures receive times,
and applies offset/delay corrections. The current initialization topology model
is linear and ordered by scan position. A separate DC runtime sends FRMW
maintenance and periodic `0x092C` diagnostics; it tracks lock against the configured
threshold and applies the selected lock-loss policy.

Slave-local `EtherCAT.Slave.Sync.Config` describes SYNC0, SYNC1, and latch intent.
Hardware-generated SYNC pulses can decouple device application timing from host
jitter **when process data arrives before the required deadline**. DC does not
make frame transmission hardware-timed, eliminate BEAM/OS jitter, or rescue late
PDO data. Clock precision, sustainable cycle rate, and watchdog behavior must be
measured on the actual hardware under representative load. There is no universal
frame-time budget or hard real-time guarantee in this library.

## Driver and simulator boundary

`EtherCAT.Driver` declares named mappings over discovered PDOs and codecs for the
registered directions. `describe/1` provides offline metadata; it does not invoke
layout discovery. Codecs return explicit success/error tuples. Callbacks execute
synchronously in the slave and should remain pure and fast.

Optional `EtherCAT.Driver.Provisioning` callbacks supply mailbox/sync setup.
Simulation stays separate: `EtherCAT.Simulator.Adapter` supplies authored device
options, and `Simulator.Slave.from_driver/2` combines those options with declared
identity defaults. Mapping declarations alone cannot infer a simulator's object
dictionary or device behavior.

The separately started simulator owns datagram execution, segment state,
snapshots, and deterministic runtime faults. Its UDP/raw endpoints own transport
faults. It models protocol behavior, not a physical ESC or a complete DC/wire
latency model. See the [simulator guide](lib/ethercat/simulator.md),
[scenario suite](test/integration/simulator/README.md), and
[hardware guide](test/integration/hardware/README.md).

## Implementation entry points

- `lib/ethercat.ex` — supported application runtime API
- `lib/ethercat/master.ex` and `master/fsm.ex` — lifecycle coordination
- `lib/ethercat/slave.ex` and `slave/fsm.ex` — ESM and device runtime
- `lib/ethercat/domain.ex` and `domain/cycle.ex` — cyclic image ownership
- `lib/ethercat/bus.ex` and `bus/link/` — scheduler and exchange execution
- `lib/ethercat/dc.ex` — initialization and runtime lock monitoring
- `lib/ethercat/simulator.ex` and `simulator.md` — virtual segment boundary

State machines use `:state_enter` for side effects and timer setup only. State
transitions are selected by event handlers, never by enter callbacks.
