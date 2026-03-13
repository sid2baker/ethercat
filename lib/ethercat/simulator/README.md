# EtherCAT Simulator

Simulated EtherCAT slave segment used for deep integration tests, local virtual
hardware, and higher-level tooling.

Keep this file short. The long-form simulator notes now live in focused
companion docs in this directory.

## Purpose

The simulator exists to boot the real master against a deterministic peer
without physical hardware while keeping the runtime path real:

- real `EtherCAT.start/1`
- real `EtherCAT.Bus`
- real `EtherCAT.Bus.Link.SinglePort`
- real `EtherCAT.Bus.Transport.UdpSocket`
- simulated slaves behind a real UDP endpoint on the EtherCAT UDP port

This is not a production field-device implementation. It is a
protocol-faithful simulator for tests and tooling.

## Read This In Order

Start with the source-adjacent module briefing:

- `lib/ethercat/simulator.md`

Then use the focused subtree docs:

- `ARCHITECTURE.md`
- `CAPABILITIES.md`
- `FAULTS.md`
- `TESTING.md`

The design source still lives in the derived SOES notes under
`slave/reference/slave_spec/`:

- `slave/reference/slave_spec/README.md`
- `slave/reference/slave_spec/runtime.md`
- `slave/reference/slave_spec/object_model.md`
- `slave/reference/slave_spec/process_data.md`
- `slave/reference/slave_spec/elixir_target.md`

## Navigation

- `ARCHITECTURE.md`
  - runtime shape
  - module structure
  - protocol-fidelity boundary
  - SII/PDO/WKC rules
  - UDP loopback rationale
  - scale boundaries
- `CAPABILITIES.md`
  - current implemented surface
  - device scope
  - widget-facing signal API
  - generalized slave coverage
- `FAULTS.md`
  - sticky vs queued faults
  - runtime vs UDP-edge corruption
  - mailbox fault shapes
  - delay semantics
  - intentional fault-model limits
- `TESTING.md`
  - simulator + hardware integration coverage
  - fixture tiers
  - scenario philosophy
  - milestone coverage
- `slave/reference/slave_spec/README.md`
  - authoritative design source derived from SOES inputs

## Current Status

The simulator is now a real library feature under `lib/ethercat/simulator*`,
not a `test/support` helper.

What is already implemented and validated:

- one or more simulated slaves behind one named simulator instance
- real UDP transport path through `EtherCAT.Bus.Transport.UdpSocket`
- startup addressing modes:
  - broadcast
  - auto-increment
  - fixed-address
  - logical
- AL transition discipline:
  - `INIT -> PREOP -> SAFEOP -> OP`
- SII/EEPROM reads through the normal master path
- SyncManager and FMMU programming
- cyclic LRW process-data exchange
- expedited and segmented CoE mailbox coverage
- deterministic runtime and UDP-edge fault injection
- signal-level get/set, subscriptions, and snapshots for tooling
- real-device hydration through simulator companions on real drivers

Use the companion docs for the detailed behavior surface instead of extending
this entrypoint into another all-in-one design log.

## Historical Plans

- [docs/exec-plans/completed/simulator-runtime-refactor.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/simulator-runtime-refactor.md)
- [docs/exec-plans/completed/simulator-generalization.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/simulator-generalization.md)
