# Simulator Generalization

Status: ACTIVE

## Goal

Turn `EtherCAT.Simulator*` from a strong digital-card/test simulator into a
general simulated-slave platform that can support:

- digital I/O cards
- analog cards
- RTD / temperature cards
- smarter mailbox-driven devices
- servo / CiA 402 style profile tests
- future UI tooling such as a `kino_ethercat` simulator widget

This plan is specifically about the simulator layer under
`lib/ethercat/simulator*`, not the production master runtime.

## Current Baseline

Already implemented:

- UDP loopback endpoint via `EtherCAT.Simulator.Udp`
- multi-slave simulator core via `EtherCAT.Simulator`
- fixture and signal API via `EtherCAT.Simulator.Slave`
- digital / coupler / LAN9252-style fixtures
- expedited CoE upload/download
- deterministic fault injection
- deep integration tests for startup, cyclic I/O, PREOP mailbox use, and
  runtime recovery

Main limitations:

- device behavior is still fixture-centric and mostly static
- object dictionary is too small and too untyped
- PDO modeling is still oriented around small byte-like fixtures
- no reusable analog/temperature/servo profiles yet
- no segmented CoE transfers
- no widget-grade signal subscriptions
- no DC-aware simulated slave behavior

## Design Principles

1. Keep the core protocol-faithful.
2. Keep profile behavior out of the generic ESC/datagram core.
3. Prefer declarative fixture/profile definitions over hardcoded branches.
4. Grow the public simulator API deliberately; do not leak every internal
   helper as public surface.
5. Preserve the existing deep integration path through the real UDP transport.

## Target Shape

The simulator should converge toward three layers:

1. Generic protocol core
   - datagram routing
   - register behavior
   - AL state discipline
   - SII / mailbox / process-image mechanics
2. Declarative slave description
   - identity
   - SII
   - object dictionary
   - PDO model
   - SyncManagers / capabilities
3. Device behavior and profiles
   - digital, analog, temperature, servo, etc.
   - dynamic input/output behavior
   - profile-specific state and validation

## Phase 1. Stabilize The Public Simulator Boundary

Goal:
- make `EtherCAT.Simulator`, `EtherCAT.Simulator.Udp`, and
  `EtherCAT.Simulator.Slave` the clear public API

Work:
- review what under `EtherCAT.Simulator.Slave.*` should remain public
- keep only `Simulator`, `Simulator.Udp`, and `Simulator.Slave` as intended
  user-facing modules
- document value semantics and fault-injection semantics explicitly
- add subscriptions or polling guidance for widget consumers

Exit criteria:
- `kino_ethercat` can depend on the simulator API without reaching into
  private helper modules

## Phase 2. Introduce A Real Device Behavior Boundary

Goal:
- separate protocol core from simulated device behavior

Work:
- add something like `EtherCAT.Simulator.Slave.Behaviour`
- define callbacks for:
  - init
  - transition hooks
  - output write handling
  - input refresh
  - mailbox/object access hooks
  - optional periodic evolution hooks
- reimplement the current digital fixtures on that behavior boundary

Exit criteria:
- no fixture-specific digital behavior remains embedded in the generic device
  core

## Phase 3. Generalize The Object Dictionary

Goal:
- move from raw mailbox branches to a real typed object model

Work:
- add typed object entry definitions
- add access-right checks
- add state-aware access rules
- add segmented upload/download
- add more complete abort behavior
- optionally add a minimal SDO info surface

Exit criteria:
- mailbox-capable fixtures declare object dictionaries as data
- deep tests cover both expedited and segmented transfers

## Phase 4. Generalize Process Data

Goal:
- support realistic non-digital PDO/process-image layouts

Work:
- add typed PDO entry definitions
- support arbitrary bit/byte offsets
- support signed/unsigned/float conversion
- support scaling and engineering-unit hooks
- support grouped process-image layouts and multi-SM fixtures

Exit criteria:
- one analog-style fixture can be modeled without bespoke byte-level code

## Phase 5. Add Reusable Profiles

Goal:
- make common slave families reusable instead of ad-hoc fixture code

Initial profiles:
- `DigitalIO`
- `AnalogIO`
- `TemperatureInput`
- `MailboxDevice`
- later `ServoDrive`

Work:
- move device-family semantics into profile modules
- keep fixtures as thin declarations over shared profile logic
- define profile-specific signal metadata and validation

Exit criteria:
- heterogeneous deep tests use profiles, not one-off fixture behavior

## Phase 6. Add Widget-Oriented Runtime Features

Goal:
- support simulator-driven UI tooling well

Work:
- add change notifications or subscriptions for signal updates
- expose richer signal metadata:
  - type
  - width
  - engineering-unit/scaling hints
  - direction
  - profile grouping
- add ring-level introspection helpers
- add profile-aware validation for `set_value/4`

Exit criteria:
- a `kino_ethercat` widget can create and drive a virtual ring with minimal
  custom glue

## Phase 7. Add Servo / Drive Support

Goal:
- support realistic drive-profile tests without turning the simulator into a
  physics engine

Work:
- add a servo/drive profile
- add controlword/statusword behavior
- add mode-of-operation handling
- add drive fault/reset/enable progression hooks
- add profile-specific object dictionary entries and PDO layouts

Exit criteria:
- a deep integration test can boot a simulated drive, configure it, and run a
  basic enable/fault-reset/status sequence

## Phase 8. Add Optional DC-Aware Behavior

Goal:
- support tests for DC-sensitive slaves without forcing DC on every fixture

Work:
- add opt-in DC register behavior
- add sync-related mailbox/object behavior where needed
- add deterministic lock/loss simulation hooks
- add latch/timestamp support where relevant

Exit criteria:
- at least one DC-aware simulated slave participates in a deep integration
  test

## Recommended Order

Highest-value order:

1. public simulator boundary cleanup
2. behavior boundary
3. typed object dictionary
4. typed PDO/process-data model
5. first analog profile
6. widget-oriented subscriptions/introspection
7. servo/drive profile
8. optional DC support

That order keeps the simulator reusable instead of baking advanced device
semantics into the current digital-card core.

## Validation Strategy

Each phase should add both:

- focused simulator unit tests
- at least one real deep integration test through `EtherCAT.Simulator.Udp`

Raw-socket coverage remains a separate concern and should stay on real hardware
for now.
