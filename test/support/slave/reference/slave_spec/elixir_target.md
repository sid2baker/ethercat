# Elixir Target

## Goal

Build a deterministic BEAM-side slave simulator that is good enough to drive
deep integration tests against the real master.

It should be derived from SOES concepts, but implemented for the needs of this
repo:

- startup verification
- process-data round trips
- deterministic fault injection
- later mailbox/CoE coverage

## Current Target Mapping

| SOES concept | Elixir support module |
| --- | --- |
| one slave application instance | `EtherCAT.Support.Slave.Device` |
| fixture identity + SII/process image | `EtherCAT.Support.Slave.Fixture` |
| slave-facing driver for tests | `EtherCAT.Support.Slave.Driver` |
| slave segment/ring execution | `EtherCAT.Support.Simulator` |
| transport endpoint | `EtherCAT.Support.Simulator.Udp` |

## What Must Be Faithful

The simulator must be faithful at the protocol boundary:

- datagram routing
- register reads/writes
- AL control/status behavior
- EEPROM/SII read behavior
- SyncManager/FMMU state
- logical process-data access
- WKC accounting

That is the part the master actually sees.

## What Can Be Simplified

The simulator does **not** need to copy SOES internals like:

- embedded polling loops
- HAL abstraction shape
- hardware interrupt behavior
- exact driver callback structure

Those are implementation details of the C stack, not protocol requirements for
our tests.

## Milestone Guidance

### Milestone 1

Keep only:

- one static digital I/O fixture
- normal startup to `:operational`
- cyclic process-image roundtrip

### Milestone 2

Add:

- multiple slaves in one simulator
- realistic startup count/station assignment behavior
- multi-slave logical image coverage

Current status:

- implemented with one-segment multi-slave routing in `EtherCAT.Support.Simulator`
- covered by deep tests for:
  - two homogeneous digital I/O slaves
  - one coupler fixture plus one LAN9252-style I/O fixture

### Milestone 3

Add mailbox/CoE only when the master/runtime tests actually need it:

- upload/download basics
- deterministic object values
- PREOP driver mailbox configuration

Current status:

- expedited upload/download basics are implemented
- mailbox-capable fixtures expose deterministic object values
- the deep integration suite covers PREOP public `upload_sdo/3` and
  `download_sdo/4`
- segmented transfers and driver-driven mailbox configuration are still pending

### Milestone 4

Add explicit fault injection:

- no response
- wrong WKC
- AL error latch
- retreat to `SAFEOP`
- mailbox error replies

## Deep Test Philosophy

The deep integration path should stay as close to the real runtime as possible.

For the current repo, that means:

- use the real master
- use the real bus
- use the real UDP transport
- use loopback sockets for convenience
- leave raw socket coverage to real hardware for now

That gives strong coverage without forcing the simulator to solve every
hardware-specific concern at once.
