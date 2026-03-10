# EtherCAT Simulator

## Purpose

This directory contains the simulated slave runtime used for:

- deep integration tests in this repo
- local hardware simulation
- higher-level tools such as a future `kino_ethercat` simulator widget

The goal is to boot the real master against a deterministic peer without
physical hardware while keeping the runtime path real:

- real `EtherCAT.start/1`
- real `EtherCAT.Bus`
- real `EtherCAT.Bus.Link.SinglePort`
- real `EtherCAT.Bus.Transport.UdpSocket`
- simulated slaves behind a real UDP endpoint on the EtherCAT UDP port

This is not a production field-device implementation. It is a protocol-faithful
simulator for tests and tooling.

## Read This In Order

The working specification lives in the derived SOES notes under
`reference/slave_spec/`.

Start with:

- `reference/slave_spec/README.md`

Then use the focused notes:

- `reference/slave_spec/runtime.md`
- `reference/slave_spec/object_model.md`
- `reference/slave_spec/process_data.md`
- `reference/slave_spec/elixir_target.md`

This README should stay aligned with those files. The `slave_spec` folder is
the design source; this README is the implementation overview.

## Current Status

The simulator is now a real library feature under `lib/ethercat/simulator*`,
not a `test/support` helper.

What is already implemented and validated:

- one or more simulated slaves behind one simulator instance
- real UDP transport path through `EtherCAT.Bus.Transport.UdpSocket`
- startup addressing modes:
  - broadcast
  - auto-increment
  - fixed-address
  - logical
- basic AL transition discipline:
  - `INIT -> PREOP -> SAFEOP -> OP`
- SII/EEPROM reads through the normal master path
- SyncManager/FMMU programming
- cyclic LRW process-data exchange
- heterogeneous startup rings (`coupler` + I/O fixtures)
- expedited CoE upload/download for mailbox-capable fixtures
- deterministic fault injection:
  - dropped responses
  - wrong WKC
  - slave disconnect / reconnect
  - `SAFEOP` retreat
  - AL error latch
  - mailbox abort replies
- signal-level get/set API for external tooling

The simulator is already strong enough to exercise the real master through:

- startup to `:operational`
- cyclic I/O roundtrips
- PREOP mailbox diagnostics
- recovery from realistic runtime faults

## Current Runtime Shape

The simulator is intentionally event-driven.

Unlike SOES, there is no embedded polling loop equivalent to `ecat_slv()`.
Instead, incoming EtherCAT datagrams drive all state changes:

- register reads/writes
- AL control/status transitions
- EEPROM data fetches
- SyncManager/FMMU programming
- logical process-data access

That matches the requirement in `reference/slave_spec/runtime.md`: preserve the
observable protocol boundary, not the C control flow.

## Structure

Runtime implementation:

```text
lib/ethercat/
├── simulator.ex
└── simulator/
    ├── udp.ex
    └── slave/
        ├── device.ex
        ├── driver.ex
        ├── fixture.ex
        ├── mailbox.ex
        └── signals.ex
```

Reference/spec material remains under:

```text
lib/ethercat/simulator/
├── README.md
└── slave/
    └── reference/
        ├── slave_spec.md
        ├── slave_spec/
        └── soes/
```

Main modules:

- `EtherCAT.Simulator`
  - public simulator process
  - multi-slave datagram routing and WKC accumulation
- `EtherCAT.Simulator.Udp`
  - real UDP endpoint, defaulting to EtherCAT UDP port `0x88A4`
- `EtherCAT.Simulator.Slave`
  - public fixture and simulator-facing signal API
- `EtherCAT.Simulator.Slave.Fixture`
  - declarative identity, EEPROM, and process-image definition
- `EtherCAT.Simulator.Slave.Signals`
  - signal metadata derived from the support driver model
- `EtherCAT.Simulator.Slave.Device`
  - one simulated slave instance with ESC memory and AL state
## Current Concept Mapping

This mirrors `reference/slave_spec/elixir_target.md`.

| SOES concept | Elixir support module |
| --- | --- |
| one slave application instance | `EtherCAT.Simulator.Slave.Device` |
| fixture identity + SII/process image | `EtherCAT.Simulator.Slave.Fixture` |
| slave-facing driver for tests | `EtherCAT.Simulator.Slave.Driver` |
| slave segment/ring execution | `EtherCAT.Simulator` |
| transport endpoint | `EtherCAT.Simulator.Udp` |

Translate SOES concepts, not C files or callback structure.

## What Must Stay Faithful

These are the protocol-facing parts the master actually sees. They should stay
aligned with `reference/slave_spec/runtime.md` and
`reference/slave_spec/process_data.md`.

- datagram routing:
  - broadcast
  - auto-increment
  - fixed-address
  - logical
- register reads/writes
- AL control/status behavior
- EEPROM/SII read behavior
- SyncManager and FMMU state
- logical process-data read/write behavior
- WKC accounting

## What Is Intentionally Simplified

These are still intentionally out of scope today.

- embedded polling-loop shape from SOES
- HAL/device-driver structure
- hardware interrupt behavior
- raw-socket simulation
- link-carrier modeling
- full DC behavior

This matches `reference/slave_spec/elixir_target.md`: preserve protocol
behavior, not implementation detail.

## Current Fixture Scope

The simulator now ships with three compiled fixture shapes:

- `digital_io/1`
  - one output byte
  - one input byte
  - SM2 output mapping
  - SM3 input mapping
- `lan9252_demo/1`
  - two output bytes
  - one input byte
  - explicit SOES-style small digital I/O shape
- `coupler/1`
  - no PDOs
  - startup-only placeholder for heterogeneous rings

The `lan9252_demo/1` fixture is the current closest match to the SOES LAN9252
demo described in `reference/slave_spec/object_model.md`.

It is also the first mailbox-capable fixture:

- PREOP mailbox SMs are described in SII
- expedited CoE upload/download is supported for small deterministic object
  values
- the current object dictionary surface is intentionally tiny and test-oriented

## Current Deep Integration Coverage

The simulator is exercised through the normal deep integration suite in:

- [`test/ethercat/deep_integration_test.exs`](/home/n0gg1n/Development/Work/opencode/ethercat/test/ethercat/deep_integration_test.exs)

The current suite proves:

1. one simulated digital I/O slave can boot to `:operational`
2. two simulated digital I/O slaves can share one simulator instance
3. a heterogeneous ring can boot with:
   - a coupler fixture in slot 0
   - a mailbox-capable LAN9252-style I/O fixture in slot 1
4. expedited CoE upload/download works in PREOP through the public mailbox API
5. runtime recovery works for:
   - wrong WKC
   - dropped UDP responses
   - disconnect / reconnect of one simulated slave
   - disconnect / reconnect of one slave in a shared domain
6. simulator-driven value injection and output observation work through the
   signal-level API

## Widget-Facing Signal API

The simulator now exposes a small signal-oriented API intended for higher-level
tools like a `kino_ethercat` simulator widget.

For fixture introspection:

```elixir
fixture = EtherCAT.Simulator.Slave.lan9252_demo(name: :io)

EtherCAT.Simulator.Slave.signals(fixture)
#=> [:led0, :led1, :button1]

EtherCAT.Simulator.Slave.signal_definitions(fixture)
#=> %{button1: %{direction: :input, ...}, led0: %{direction: :output, ...}, ...}
```

For runtime control of a running simulator:

```elixir
{:ok, simulator} =
  EtherCAT.Simulator.start_link(slaves: [fixture])

EtherCAT.Simulator.Slave.set_value(simulator, :io, :button1, 7)
EtherCAT.Simulator.Slave.get_value(simulator, :io, :led0)
EtherCAT.Simulator.Slave.signals(simulator, :io)
```

Current semantics:

- values are read and written by named signal
- `set_value/4` accepts integers, booleans, or exact-size binaries
- `get_value/3` currently returns raw integer values
- input values set through this API persist even on fixtures that also mirror
  outputs into inputs by default

That keeps the API generic enough for a UI widget without tying it to a
specific device profile or driver callback contract.

What is still missing for a really good widget experience:

- change notifications / subscriptions for simulator signal updates
- richer typed values in the public signal metadata
- fixture/profile discovery that is more explicit than today
- profile-aware validation for writes (for example signed ranges or analog
  engineering units)
- easy composition of multiple fixtures into a named virtual ring

## What Is Still Missing For A General Slave

The current support slave is already good enough for:

- couplers
- simple digital input cards
- simple digital output cards
- heterogeneous startup rings
- basic mailbox diagnostics
- deterministic protocol fault injection

It is **not** yet a general slave model for:

- analog input and output cards
- RTD/temperature cards with conversion behavior
- smart devices with rich object dictionaries
- servo drives and CiA 402-like profiles
- DC-sensitive devices

The missing pieces are mostly above the raw ESC/datagram layer.

### 1. A real device-behavior layer

Today most fixtures are static plus simple process-image behavior.

A general slave needs profile/device logic that can:

- evolve inputs over time
- react to outputs
- simulate internal state machines
- enforce device-specific operating rules
- inject realistic delays, saturation, and device faults

### 2. A richer object-dictionary model

Mailbox support is still limited to small expedited SDO roundtrips.

A general slave needs:

- typed object entries
- access rights
- state-dependent access control
- segmented upload/download
- richer abort behavior
- optional SDO info support

### 3. A richer PDO/process-data model

The current fixtures are still card-oriented.

A general slave needs:

- arbitrary PDO entry definitions
- signed/unsigned/float signal types
- scaling and conversion hooks
- grouped process images
- multi-SM layouts
- profile-specific signal bundles

### 4. Profile layers on top of the generic slave core

The generic support slave should stay protocol-focused.

Device-family behavior should live in separate profile layers for:

- digital I/O
- analog I/O
- RTD/temperature
- servo/drive devices

### 5. More realistic state/transition discipline

The simulator already enforces basic AL transition rules, but a general slave
needs more profile-aware discipline:

- mailbox-required transitions
- SAFEOP/OP prerequisites
- watchdog/safe-state behavior
- profile-specific error latching and recovery

### 6. Optional DC behavior

Not every deep test needs DC, but a general slave eventually needs:

- DC register behavior
- sync configuration
- lock/loss behavior
- latch/timestamp semantics where relevant

## Missing Features Summary

The simulator is already good at:

- deterministic EtherCAT protocol behavior
- digital-card-style fixtures
- mailbox happy-path coverage
- recovery and fault-injection tests

The main missing pieces for “all kinds of slaves” are:

- a real device behavior abstraction
- a typed object dictionary
- richer typed PDO/process-data modeling
- reusable device profiles
- servo / CiA 402 profile behavior
- optional DC-aware slave behavior
- widget-oriented signal subscriptions and live introspection

## Generalization Direction

The right way to grow this support stack is:

1. keep the existing ESC/datagram core stable
2. add a proper generic device model
3. layer richer profiles on top of it
4. only then add profile-specific deep tests

The concrete execution plan for that work lives at:

- [docs/exec-plans/active/simulator-generalization.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/active/simulator-generalization.md)

### Phase 1. Stabilize The Generic Protocol Core

Goal:
- keep `EtherCAT.Simulator.Slave.Device` and `EtherCAT.Simulator`
  responsible for protocol mechanics only

Deliverables:
- no profile-specific behavior in the core
- clear boundaries between:
  - registers/AL state
  - SII/object model
  - PDO layout
  - runtime behavior hooks

Exit criteria:
- digital I/O and mailbox tests still pass unchanged

### Phase 2. Introduce A Real Device Behavior Boundary

Goal:
- make slave behavior pluggable instead of hardcoded into fixture/device logic

Add something like:
- `EtherCAT.Simulator.Slave.Behaviour`
- behavior callbacks for:
  - init
  - state transition hooks
  - output write handling
  - input refresh
  - mailbox/object access hooks

Exit criteria:
- digital I/O fixtures are reimplemented using the behavior boundary
- no special-case digital behavior remains embedded in the core

### Phase 3. Generalize The Object Dictionary

Goal:
- move from a tiny mailbox test dictionary to a real typed object model

Add:
- object entry structs/types
- access-right checks
- state-aware access rules
- segmented transfer support

Exit criteria:
- expedited and segmented CoE transfers both work
- object entries can be declared as data, not mailbox callback branches

### Phase 4. Generalize Process Data

Goal:
- support more than simple byte-oriented digital process images

Add:
- typed PDO entries
- arbitrary bit/byte offsets
- signed/unsigned/float conversion
- scaling hooks
- grouped output/input images

Exit criteria:
- one analog-style fixture can be modeled without bespoke device code
- multi-byte/multi-type PDO layouts are deep-tested

### Phase 5. Add First-Class Profiles

Goal:
- make common slave families reusable instead of fixture-specific

Initial profiles:
- `DigitalIO`
- `AnalogIO`
- `TemperatureInput`
- `ServoDrive` (protocol/profile only, not full motion physics)

Exit criteria:
- fixtures become thin declarations over shared profile modules
- heterogeneous deep tests use profile modules, not ad-hoc fixture logic

### Phase 6. Add Servo/Drive-Oriented Support

Goal:
- support richer smart-slave regression tests, especially CiA 402-like flows

Add:
- controlword/statusword-oriented behavior
- operation mode handling
- drive-state progression hooks
- profile-specific mailbox/object entries

Exit criteria:
- deep tests can boot a simulated drive, configure it in PREOP, and exercise a
  basic enable/fault-reset/status roundtrip

### Phase 7. Add Optional DC Support

Goal:
- support tests for DC-sensitive slaves without forcing DC on every fixture

Add:
- opt-in DC register behavior
- sync-related mailbox/object state where needed
- deterministic lock/loss simulation hooks

Exit criteria:
- at least one DC-aware simulated slave can participate in a deep test

## Recommended Near-Term Order

If the goal is "all kinds of slaves", the highest-value next steps are:

1. introduce the behavior boundary
2. generalize the object dictionary
3. generalize PDO/process-data typing
4. add a first analog-style profile
5. only then tackle servo/drive profile support

That order keeps the core reusable instead of baking servo or analog semantics
directly into the current digital-card simulator.

## EEPROM / SII Strategy

The EEPROM image is fixture-owned.

It must provide enough data for the master’s existing SII parser to discover:

- identity
- mailbox metadata
- SyncManager categories
- PDO categories

This aligns with `reference/slave_spec/object_model.md`: the important thing is
the semantic device shape, not a 1:1 port of `slave_objectlist.c`.

## Process-Data Rules

The current simulator follows the rules captured in
`reference/slave_spec/process_data.md`.

### Routing

The simulator already supports:

- `BRD` / `BWR` / `BRW`
- `APRD` / `APWR` / `APRW`
- `FPRD` / `FPWR` / `FPRW`
- `LRD` / `LWR` / `LRW`

### WKC

WKC is derived from actual command effect:

- read contribution = `1`
- write contribution = `2`
- read + write contribution = `3`

It should stay explicit and unit-testable.

## Why UDP Loopback

The deep integration path uses the real UDP transport over loopback:

- master bind IP: `127.0.0.1`
- simulator bind IP: `127.0.0.2`
- simulator endpoint default port: `0x88A4` (`34980`)

This gives:

- real kernel UDP sockets
- real frame encode/decode
- real master startup and cyclic behavior
- no root requirement

It does not try to simulate:

- `RawSocket`
- carrier loss
- unplug/replug

Those remain hardware concerns for now.

## Frame Reuse

Do not reimplement frame parsing.

The simulator should keep reusing:

- `EtherCAT.Bus.Frame`
- `EtherCAT.Bus.Datagram`

The support code owns only:

- datagram semantics
- register behavior
- process-image behavior
- WKC calculation

## Deep Integration Tests

The current deep integration coverage lives in:

- `test/ethercat/deep_integration_test.exs`

It now covers three end-to-end flows through the real UDP transport:

1. one simulated digital I/O slave boots to `:operational`
2. two simulated digital I/O slaves boot on one segment and exchange
   independent cyclic I/O
3. a heterogeneous ring boots with:
   - one `coupler/1` fixture
   - one `lan9252_demo/1` fixture
4. one mailbox-capable `lan9252_demo/1` slave boots to `:preop_ready` and
   serves expedited CoE upload/download requests through the public API

The heterogeneous test proves:

- normal slave counting and station assignment
- startup through a no-PDO placeholder in slot 0
- cyclic I/O against a richer PDO-mapped slave in slot 1
- multi-byte output image handling through the public API

These tests should keep running under normal `mix test`.

## Next Milestones

These should stay aligned with `reference/slave_spec/elixir_target.md`.

### Milestone 1

- one static digital I/O slave
- real UDP loopback transport
- boot to `:operational`
- cyclic I/O roundtrip

### Milestone 2

- multiple slaves in one simulator
- realistic startup count and station assignment behavior
- multi-slave logical image coverage

### Milestone 3

- mailbox / CoE basics
- deterministic SDO values
- PREOP driver mailbox integration tests

Current status:

- expedited CoE upload/download is implemented for mailbox-capable fixtures
- the deep integration suite now exercises public `upload_sdo/3` and
  `download_sdo/4` against a simulated slave in PREOP
- segmented transfers are still future work
- mailbox error replies are implemented through explicit abort injection

### Milestone 4

- explicit fault injection:
  - no response
  - wrong WKC
  - slave disconnect / reconnect
  - AL error latch
  - retreat to `SAFEOP`
  - mailbox error replies

Current status:

- persistent transport fault injection is implemented for:
  - no response
  - wrong WKC
- simulator-level disconnect/reconnect is implemented by temporarily removing a
  named slave from AP/FP/BR/logical routing until faults are cleared
- slave-local fault injection is implemented for:
  - AL error latch
  - retreat to `SAFEOP`
- mailbox abort injection is implemented for deterministic CoE error replies
- the deep integration suite now exercises:
  - `:recovering` entry and recovery for dropped UDP responses
  - `:recovering` entry and recovery for wrong WKC
  - `:recovering` entry and recovery for disconnecting and reconnecting a
    PDO-participating slave
  - `SAFEOP` retreat reporting through slave health polling
  - SDO abort replies through the public mailbox API

## SOES Inputs

The raw reference material is kept in `reference/soes/`. The most relevant
inputs are:

- `reference/soes/README.md`
- `reference/soes/soes/doc/tutorial.txt`
- `reference/soes/applications/linux_lan9252demo/main.c`
- `reference/soes/applications/linux_lan9252demo/slave_objectlist.c`
- `reference/soes/applications/linux_lan9252demo/utypes.h`

Use those through the derived `reference/slave_spec/` notes, not by copying the
C structure directly.
