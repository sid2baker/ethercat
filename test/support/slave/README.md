# EtherCAT Support Simulator

## Purpose

This directory contains the **test-only simulated slave runtime** used for deep
integration tests.

The goal is to boot the real master against a deterministic peer without
physical hardware while keeping the runtime path real:

- real `EtherCAT.start/1`
- real `EtherCAT.Bus`
- real `EtherCAT.Bus.Link.SinglePort`
- real `EtherCAT.Bus.Transport.UdpSocket`
- simulated slaves behind a real UDP endpoint

This is not a production slave implementation. It is a protocol-faithful test
fixture.

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

Compiled in `MIX_ENV=test`:

```text
test/support/
├── simulator.ex
├── simulator/
│   └── udp.ex
├── slave.ex
└── slave/
    ├── README.md
    ├── device.ex
    ├── driver.ex
    ├── fixture.ex
    └── reference/
        ├── slave_spec.md
        ├── slave_spec/
        └── soes/
```

Main modules:

- `EtherCAT.Support.Slave`
  - public fixture boundary
- `EtherCAT.Support.Slave.Fixture`
  - declarative identity, EEPROM, and process-image definition
- `EtherCAT.Support.Slave.Device`
  - one simulated slave instance with ESC memory and AL state
- `EtherCAT.Support.Simulator`
  - multi-slave datagram routing and WKC accumulation
- `EtherCAT.Support.Simulator.Udp`
  - real UDP endpoint, defaulting to EtherCAT UDP port `0x88A4`

## Current Concept Mapping

This mirrors `reference/slave_spec/elixir_target.md`.

| SOES concept | Elixir support module |
| --- | --- |
| one slave application instance | `EtherCAT.Support.Slave.Device` |
| fixture identity + SII/process image | `EtherCAT.Support.Slave.Fixture` |
| slave-facing driver for tests | `EtherCAT.Support.Slave.Driver` |
| slave segment/ring execution | `EtherCAT.Support.Simulator` |
| transport endpoint | `EtherCAT.Support.Simulator.Udp` |

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

These are explicitly out of scope for the first simulator slices.

- embedded polling-loop shape from SOES
- HAL/device-driver structure
- hardware interrupt behavior
- mailbox/CoE protocol loop
- raw-socket simulation
- link-carrier modeling
- full DC behavior

This matches `reference/slave_spec/elixir_target.md`: preserve protocol
behavior, not implementation detail.

## Current Fixture Scope

The current `digital_io/1` fixture is smaller than the SOES LAN9252 demo
described in `reference/slave_spec/object_model.md`.

Today it provides:

- one output byte
- one input byte
- SM2 output mapping
- SM3 input mapping
- one output FMMU
- one input FMMU
- mirrored output-to-input behavior for the first deep I/O roundtrip test

That is enough for the current milestone, even though the SOES reference device
is slightly richer:

- two output bytes
- one input byte
- small parameter object

The next realistic step is to move the fixture closer to that reference shape
without changing the simulator architecture.

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

## Deep Integration Test

The first deep integration test is:

- `test/ethercat/deep_integration_test.exs`

Flow:

1. start `EtherCAT.Support.Simulator` with one fixture
2. start `EtherCAT.Support.Simulator.Udp` on `127.0.0.2`
3. read the actual bound UDP port from the endpoint
4. start the real master with:
   - `transport: :udp`
   - `bind_ip: {127, 0, 0, 1}`
   - `host: {127, 0, 0, 2}`
   - `port: endpoint_port`
5. boot to `:operational`
6. write output through the public API
7. verify the simulated output image changed
8. verify the mirrored input is visible through the normal cyclic LRW path

This test should keep running under normal `mix test`.

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

### Milestone 4

- explicit fault injection:
  - no response
  - wrong WKC
  - AL error latch
  - retreat to `SAFEOP`
  - mailbox error replies

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
