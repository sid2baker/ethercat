Simulated EtherCAT segment for deep integration tests and virtual hardware.

`EtherCAT.Simulator` hosts one or more simulated slaves and executes EtherCAT
datagrams against them with protocol-faithful register, AL-state, mailbox, and
logical process-data behavior.

It is the public process boundary for the simulator runtime. Device builders,
signal-level control, and signal wiring live in `EtherCAT.Simulator.Slave`,
while the real UDP endpoint lives in `EtherCAT.Simulator.Udp`.

For the full implementation guide and the SOES-derived simulator notes, see:

- `lib/ethercat/simulator/README.md`
- `lib/ethercat/simulator/slave/reference/slave_spec/README.md`

## Purpose

The simulator exists for:

- deep integration tests without physical hardware
- local virtual hardware during development
- higher-level tooling such as a future simulator widget in `kino_ethercat`

The intended runtime path stays realistic:

- real `EtherCAT.start/1`
- real `EtherCAT.Bus`
- real single-port bus link handling
- real `EtherCAT.Bus.Transport.UdpSocket`
- simulated slaves behind a real UDP endpoint

## State-Machine Boundary

`EtherCAT.Simulator` is intentionally a small process boundary over the
multi-slave segment state.

It owns:

- the simulated slave list
- datagram execution across that list
- WKC accumulation
- injected runtime faults
- signal subscriptions for tooling

It should not own device-profile logic inline. That lives in the simulator's
private slave runtime and profile modules under `lib/ethercat/simulator/slave/`.

## Public API Shape

Main entry points:

- `start/1` — start the public simulator runtime under
  `EtherCAT.Simulator.Supervisor`
- `start_link/1` — low-level in-memory simulator core only
- `stop/0` — stop the singleton simulator runtime
- `process_datagrams/1` — execute EtherCAT datagrams directly
- `inject_fault/1` / `clear_faults/0` — deterministic fault injection
- `info/0`, `device_snapshot/1`, `signal_snapshot/2`, `connection_snapshot/0`
  — stable runtime snapshots for tooling
- `slave_info/1` — compatibility-oriented per-device diagnostic lookup
- `signals/1`, `signal_definitions/1`, `get_value/2`, `set_value/3`
- `connect/2`, `disconnect/2`, `connections/0` — cross-slave signal wiring
- `subscribe/3` / `unsubscribe/3` — widget-friendly signal observation

Use `EtherCAT.Simulator.Slave` to build devices such as:

- digital I/O
- couplers
- mailbox-capable demo slaves
- analog and temperature devices
- servo/drive profiles
- or simulated devices hydrated from a real `EtherCAT.Slave.Driver` through
  `from_driver/2`

`EtherCAT.Simulator.Slave.Definition` is the public opaque authored device
type used by those builders and optional driver hydration.

## Fault Injection

The simulator supports deterministic runtime faults for integration coverage:

- dropped responses
- wrong WKC
- named slave disconnect/reconnect
- forced `SAFEOP` retreat
- AL error latch
- mailbox abort replies

This allows deep recovery tests against the real master/runtime without
physical hardware.

## Transport Split

`EtherCAT.Simulator` itself is transport-agnostic.

- `EtherCAT.Simulator.Udp` exposes it over a real UDP socket.
- `start/1` accepts `udp: [...]` when the common simulator-plus-UDP setup
  should run under the simulator supervisor.
- Raw-socket simulation is intentionally separate and not part of this module.
