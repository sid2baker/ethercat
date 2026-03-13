# Simulator Architecture

## Runtime Refactor

The simulator runtime refactor is complete:

- [docs/exec-plans/completed/simulator-runtime-refactor.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/simulator-runtime-refactor.md)

The main results are:

- `EtherCAT.Simulator` is mostly a process boundary and public API
- routing, faults, wiring, subscriptions, and snapshots are explicit
  collaborators
- `EtherCAT.Simulator.Slave.Runtime.Device` is mainly a device coordinator over
  AL, ESC image, process image, logical routing, objects, and CoE
- `EtherCAT.Slave.ESC.Registers` is reused for named register layout where it
  improves clarity without owning simulator policy

## Runtime Shape

The simulator is intentionally event-driven.

Unlike SOES, there is no embedded polling loop equivalent to `ecat_slv()`.
Incoming EtherCAT datagrams drive all state changes:

- register reads and writes
- AL control and status transitions
- EEPROM data fetches
- SyncManager and FMMU programming
- logical process-data access

That matches `slave/reference/slave_spec/runtime.md`: preserve the observable
protocol boundary, not the C control flow.

## Structure

Runtime implementation:

```text
lib/ethercat/
├── simulator.ex
└── simulator/
    ├── README.md
    ├── ARCHITECTURE.md
    ├── CAPABILITIES.md
    ├── FAULTS.md
    ├── TESTING.md
    ├── runtime/
    │   ├── faults.ex
    │   ├── router.ex
    │   ├── snapshot.ex
    │   ├── subscriptions.ex
    │   └── wiring.ex
    ├── udp.ex
    └── slave/
        ├── behaviour.ex
        ├── definition.ex
        ├── driver.ex
        ├── object.ex
        ├── profile.ex
        ├── profile/
        ├── reference/
        ├── runtime/
        │   ├── al.ex
        │   ├── coe.ex
        │   ├── device.ex
        │   ├── dictionary.ex
        │   ├── esc_image.ex
        │   ├── logical.ex
        │   ├── mailbox.ex
        │   └── process_image.ex
        ├── signals.ex
        └── value.ex
```

Reference/spec material remains under:

```text
lib/ethercat/simulator/
└── slave/
    └── reference/
        ├── slave_spec.md
        ├── slave_spec/
        └── soes/
```

Main modules:

- `EtherCAT.Simulator`
  - public named simulator process
  - multi-slave datagram routing and WKC accumulation
  - sticky and scripted runtime fault injection
- `EtherCAT.Simulator.Runtime.Snapshot`
  - stable read-model assembly for widgets and tooling
- `EtherCAT.Simulator.Udp`
  - optional UDP endpoint, defaulting to EtherCAT UDP port `0x88A4`
- `EtherCAT.Simulator.Slave`
  - public device and simulator-facing signal API
- `EtherCAT.Simulator.Slave.Definition`
  - public opaque authored device definition
  - identity, PDO layout, mailbox/object-dictionary configuration, behavior
- `EtherCAT.Simulator.Slave.Behaviour`
  - pluggable device behavior boundary
- `EtherCAT.Simulator.Slave.Object`
  - typed object-dictionary entries
- `EtherCAT.Simulator.Slave.Value`
  - typed signal and object value conversion
- `EtherCAT.Simulator.Slave.Profile.*`
  - reusable device-family behavior and declarations
- `EtherCAT.Simulator.Slave.Signals`
  - signal metadata derived from the support driver model
- `EtherCAT.Simulator.Slave.Runtime.Device`
  - one simulated slave instance with ESC memory and AL state

## Concept Mapping

This mirrors `slave/reference/slave_spec/elixir_target.md`.

| SOES concept | Elixir support module |
| --- | --- |
| one slave application instance | `EtherCAT.Simulator.Slave.Runtime.Device` |
| device identity + SII/process image | `EtherCAT.Simulator.Slave.Definition` |
| slave-facing driver for tests | `EtherCAT.Simulator.Slave.Driver` |
| slave segment/ring execution | `EtherCAT.Simulator` |
| transport endpoint | `EtherCAT.Simulator.Udp` |

Translate SOES concepts, not C files or callback structure.

## Fidelity Boundary

These are the protocol-facing parts the master actually sees. They should stay
aligned with `slave/reference/slave_spec/runtime.md` and
`slave/reference/slave_spec/process_data.md`.

Must stay faithful:

- datagram routing:
  - broadcast
  - auto-increment
  - fixed-address
  - logical
- register reads and writes
- AL control and status behavior
- EEPROM/SII read behavior
- SyncManager and FMMU state
- logical process-data read and write behavior
- WKC accounting

Intentionally simplified:

- embedded polling-loop shape from SOES
- HAL/device-driver structure
- hardware interrupt behavior
- raw-socket simulation
- link-carrier modeling
- full DC behavior

This matches `slave/reference/slave_spec/elixir_target.md`: preserve protocol
behavior, not implementation detail.

## EEPROM / SII Strategy

The EEPROM image is device-owned.

It must provide enough data for the master’s existing SII parser to discover:

- identity
- mailbox metadata
- SyncManager categories
- PDO categories

This aligns with `slave/reference/slave_spec/object_model.md`: the important
thing is the semantic device shape, not a 1:1 port of `slave_objectlist.c`.

## Process-Data Rules

The simulator follows the rules captured in
`slave/reference/slave_spec/process_data.md`.

### Routing

Supported commands:

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

The simulator-specific code owns only:

- datagram semantics
- register behavior
- process-image behavior
- WKC calculation

## Scale Boundaries

Keep simulator integration scenarios protocol-honest.

The current stack uses the same EtherCAT address widths as the runtime:

- auto-increment positions are encoded as signed 16-bit values
- configured station addresses are encoded as unsigned 16-bit values

That means a discovered topology must satisfy both:

- `slave_count <= 32_769`
- `base_station + slave_count - 1 <= 0xFFFF`

So a literal `70_000`-slave ring is not a meaningful simulator integration
test here. Treat those as address-space boundary checks in master/startup unit
tests, not as giant end-to-end simulator scenarios.

## Reference Inputs

The raw reference material is kept in `slave/reference/soes/`. The most
relevant inputs are:

- `slave/reference/soes/README.md`
- `slave/reference/soes/soes/doc/tutorial.txt`
- `slave/reference/soes/applications/linux_lan9252demo/main.c`
- `slave/reference/soes/applications/linux_lan9252demo/slave_objectlist.c`
- `slave/reference/soes/applications/linux_lan9252demo/utypes.h`

Use those through the derived `slave/reference/slave_spec/` notes, not by
copying the C structure directly.
