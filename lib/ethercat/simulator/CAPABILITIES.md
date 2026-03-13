# Simulator Capabilities

## Current Status

The simulator is already strong enough to exercise the real master through:

- startup to `:operational`
- cyclic I/O roundtrips
- PREOP mailbox diagnostics
- recovery from realistic runtime faults

Already implemented and validated:

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
- heterogeneous startup rings (`coupler` + I/O devices)
- expedited CoE upload and download for mailbox-capable devices
- segmented CoE upload and download for mailbox-capable devices
- signal-level get/set API for external tooling

For deterministic fault coverage, use the runtime and UDP fault surfaces
described in `FAULTS.md`.

## Device Scope

The public simulator API prefers real-device hydration through drivers:

- `EtherCAT.Simulator.Slave.from_driver(MyApp.EK1100, name: :coupler)`
- `EtherCAT.Simulator.Slave.from_driver(MyApp.EL1809, name: :inputs)`
- `EtherCAT.Simulator.Slave.from_driver(MyApp.EL2809, name: :outputs)`

Internal profile modules still exist, but they are implementation detail. They
provide reusable authored defaults that simulator companion modules can turn
into concrete simulator definitions.

The first-class public story is:

- simulate real devices through real drivers
- keep identity, PDO naming, and simulator hydration aligned
- reserve profile atoms for internal defaults and targeted unit tests

## Widget-Facing Signal API

The simulator exposes a small signal-oriented API intended for higher-level
tools like a future `kino_ethercat` simulator widget.

For device introspection:

```elixir
device = EtherCAT.Simulator.Slave.from_driver(MyApp.EL2809, name: :outputs)

EtherCAT.Simulator.Slave.signals(device)
#=> [:ch1, :ch2, ...]

EtherCAT.Simulator.Slave.signal_definitions(device)
#=> %{ch1: %{direction: :output, ...}, ch2: %{direction: :output, ...}, ...}
```

For runtime control of a running simulator:

```elixir
{:ok, _supervisor} =
  EtherCAT.Simulator.start(
    devices: [device],
    udp: [ip: {127, 0, 0, 2}, port: 0]
  )

{:ok, %{udp: %{port: port}}} = EtherCAT.Simulator.info()

EtherCAT.Simulator.Slave.set_value(:io, :button1, 7)
EtherCAT.Simulator.Slave.get_value(:io, :led0)
EtherCAT.Simulator.Slave.signals(:io)
```

Use `start_link/1` directly only when you need the in-memory simulator core.
Use `start/1` for the common case where a real `UdpSocket` transport should
talk to the simulator end to end. If you supervise `EtherCAT.Simulator` as a
child, `child_spec/1` follows the same supervised path as `start/1`, including
`udp: [...]`. Stop the simulator runtime with `stop/0`.

`EtherCAT.Simulator.info/0` exposes queued fault visibility for tooling and
tests through:

- `next_fault`
- `pending_faults`
- `scheduled_faults`
- UDP state under `udp`

To wire one simulated slave signal into another:

```elixir
:ok =
  EtherCAT.Simulator.Slave.connect({:out_card, :out}, {:in_card, :in})
```

Current semantics:

- values are read and written by named signal
- `set_value/3` accepts integers, booleans, or exact-size binaries
- `get_value/2` currently returns raw integer values
- input values set through this API persist even on devices that also mirror
  outputs into inputs by default

Widget-oriented features that are now implemented:

- change notifications via `subscribe/3` and `unsubscribe/3`
- richer signal metadata through `signal_definitions/1`
- stable tooling snapshots through:
  - `info/0`
  - `device_snapshot/1`
  - `signal_snapshot/2`
  - `connections/0`
- profile-aware value validation through typed signal definitions
- easy composition of multiple devices into one virtual ring
- one-call simulator + UDP endpoint setup via `EtherCAT.Simulator.start/1`
- explicit cross-slave wiring via `EtherCAT.Simulator.Slave.connect/2`
- real-device hydration through `EtherCAT.Simulator.Slave.from_driver/2`

## General-Slave Coverage

The simulator now covers all major areas from the generalization plan:

- protocol-faithful core:
  - datagram routing
  - AL state discipline
  - SII
  - SyncManagers/FMMUs
  - WKC accounting
- real device behavior boundary via `EtherCAT.Simulator.Slave.Behaviour`
- typed object dictionary via `EtherCAT.Simulator.Slave.Object`
- typed PDO/process-data conversion via `EtherCAT.Simulator.Slave.Value`
- reusable profiles:
  - `DigitalIO`
  - `AnalogIO`
  - `TemperatureInput`
  - `MailboxDevice`
  - `ServoDrive`
  - `Coupler`
- segmented CoE upload/download and abort handling
- widget-facing signal subscriptions and ring introspection
- servo/drive profile behavior with a basic CiA 402-style enable sequence
- opt-in DC-aware behavior through the servo profile

The simulator is already suitable for:

- digital input/output cards
- analog cards
- RTD/temperature-style devices
- mailbox-capable smart devices
- servo/drive profile regression tests
- heterogeneous rings mixing several device families

## Historical Plan

The simulator generalization plan is implemented end to end. The historical
plan record lives at:

- [docs/exec-plans/completed/simulator-generalization.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/simulator-generalization.md)
