# Simulator Generalization

Status: COMPLETE

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

## Outcome

The simulator now includes:

- `EtherCAT.Simulator`
- `EtherCAT.Simulator.Udp`
- `EtherCAT.Simulator.Slave`
- a device behavior boundary via `EtherCAT.Simulator.Slave.Behaviour`
- typed objects via `EtherCAT.Simulator.Slave.Object`
- typed signal/object conversion via `EtherCAT.Simulator.Slave.Value`
- reusable profiles for:
  - digital I/O
  - analog I/O
  - temperature input
  - mailbox-capable devices
  - servo/drive devices
  - couplers
- segmented CoE upload/download
- widget-facing subscriptions and signal metadata
- optional DC-aware behavior in the servo profile
- deep integration coverage through the real UDP transport

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

Result:
- landed
- higher-level tooling can depend on `EtherCAT.Simulator*` without reaching
  into helper modules

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

Result:
- landed through `EtherCAT.Simulator.Slave.Behaviour` and profile modules

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

Result:
- landed with typed objects and deep tests covering both expedited and
  segmented transfers

## Phase 4. Generalize Process Data

Goal:
- support realistic non-digital PDO/process-image layouts

Work:
- add typed PDO entry definitions
- support arbitrary bit/byte offsets
- support signed/unsigned/float conversion
- support scaling and engineering-unit hooks
- support grouped process-image layouts and multi-SM fixtures

Result:
- landed with typed PDO/process-data conversion and analog deep coverage

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

Result:
- landed; fixture constructors are thin declarations over shared profiles

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

Result:
- landed through signal metadata, get/set, subscriptions, and ring-level
  introspection

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

Result:
- landed through the servo/drive profile and CiA 402-style deep test

## Phase 8. Add Optional DC-Aware Behavior

Goal:
- support tests for DC-sensitive slaves without forcing DC on every fixture

Work:
- add opt-in DC register behavior
- add sync-related mailbox/object behavior where needed
- add deterministic lock/loss simulation hooks
- add latch/timestamp support where relevant

Result:
- landed through the DC-aware servo deep test

## Validation Outcome

The landed simulator is covered by:

- focused simulator unit tests
- CoE segmentation tests
- deep integration tests through `EtherCAT.Simulator.Udp`

Raw-socket coverage remains intentionally separate and stays on real hardware.

## Remaining Intentional Limits

The simulator still does not attempt to be:

- a raw-socket simulator endpoint
- a carrier/link simulator
- a full motion physics model
- a complete SDO Info implementation

Those are explicit scope limits, not unfinished phases of this plan.
