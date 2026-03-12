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

- one or more simulated slaves behind one named simulator instance
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
- heterogeneous startup rings (`coupler` + I/O devices)
- expedited CoE upload/download for mailbox-capable devices
- deterministic fault injection:
  - dropped responses
  - wrong WKC, globally or from one named logical slave contribution
  - slave disconnect / reconnect
  - `SAFEOP` retreat
  - AL error latch
  - mailbox abort replies
- signal-level get/set API for external tooling

Datagram/runtime fault injection now has two modes:

- sticky faults that stay active until `EtherCAT.Simulator.clear_faults/0`
- queued and scripted runtime faults injected through `EtherCAT.Simulator.inject_fault/1`
  using `EtherCAT.Simulator.Fault`
  with:
  - `Fault.next(fault)`
  - `Fault.next(fault, count)`
  - `Fault.script([step, ...])`
- delayed fault injection through:
  - `Fault.after_ms(fault, delay_ms)`
  - `Fault.after_milestone(fault, milestone)`

The current exchange-scoped fault set is:

- `:drop_responses`
- `{:wkc_offset, delta}`
- `{:command_wkc_offset, command_name, delta}`
- `{:logical_wkc_offset, slave_name, delta}`
- `{:disconnect, slave_name}`

Sequential fault scripts can also pause on:

- `Fault.wait_for(Fault.healthy_exchanges(count))`
- `Fault.wait_for(Fault.healthy_polls(slave_name, count))`
- `Fault.wait_for(Fault.mailbox_step(slave_name, step, count))`

Mailbox-local response faults now include:

- `{:mailbox_abort, slave_name, index, subindex, abort_code}`
- `{:mailbox_abort, slave_name, index, subindex, abort_code, stage}`
- `{:mailbox_protocol_fault, slave_name, index, subindex, stage, fault_kind}`

Direct mailbox-local injections stay active until
`EtherCAT.Simulator.clear_faults/0`. The same mailbox protocol fault injected
as a step inside `Fault.script/1` is consumed on first match, which makes
scripted reconnect/retry scenarios able to fail once and self-heal on a later
master retry.

Current mailbox protocol fault kinds:

- `:drop_response`
- `:counter_mismatch`
- `:toggle_mismatch`
- `{:mailbox_type, type}`
- `{:coe_service, service}`
- `:invalid_coe_payload`
- `{:sdo_command, command}`
- `:invalid_segment_padding`
- `{:segment_command, command}`

The simulator is already strong enough to exercise the real master through:

- startup to `:operational`
- cyclic I/O roundtrips
- PREOP mailbox diagnostics
- recovery from realistic runtime faults

## Runtime Refactor

The simulator runtime refactor is now complete:

- [docs/exec-plans/completed/simulator-runtime-refactor.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/simulator-runtime-refactor.md)

The main results are:

- `EtherCAT.Simulator` is now mostly a process boundary and public API
- routing, faults, wiring, subscriptions, and snapshots are explicit
  collaborators
- `EtherCAT.Simulator.Slave.Runtime.Device` is now mainly a device coordinator over
  AL, ESC image, process image, logical routing, objects, and CoE
- `EtherCAT.Slave.ESC.Registers` is reused for named register layout where it
  improves clarity without owning simulator policy

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
    ├── README.md
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
├── README.md
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

Drivers can also opt in directly. A real `EtherCAT.Slave.Driver` may expose:

- `identity/0`
  - static vendor/product/revision metadata for discovery and tooling
- `signal_model/1`
  - the runtime-facing logical signal declarations for the real slave
- `MyDriver.Simulator`
  - an optional simulator companion implementing
    `EtherCAT.Simulator.DriverAdapter`
  - it returns simulator definition options used by
    `EtherCAT.Simulator.Slave.from_driver/2`

That keeps simulator hydration close to the real driver without requiring
drivers to hand-author raw ESC register maps or SII binaries.

## Current Concept Mapping

This mirrors `reference/slave_spec/elixir_target.md`.

| SOES concept | Elixir support module |
| --- | --- |
| one slave application instance | `EtherCAT.Simulator.Slave.Runtime.Device` |
| device identity + SII/process image | `EtherCAT.Simulator.Slave.Definition` |
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

## Current Device Scope

The public simulator API now prefers real-device hydration through drivers:

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

## Current Integration Coverage

Repository integration coverage now has two variants built around the same real
drivers:

- [`test/integration/simulator/ring_test.exs`](/home/n0gg1n/Development/Work/opencode/ethercat/test/integration/simulator/ring_test.exs)
- [`test/integration/hardware/ring_test.exs`](/home/n0gg1n/Development/Work/opencode/ethercat/test/integration/hardware/ring_test.exs)

Both variants use the same ring model:

- EK1100 coupler
- EL1809 input terminal
- EL2809 output terminal

The simulator variant proves the real master can:

1. boot the ring to `:operational`
2. identify each device through the real drivers
3. read EL1809 inputs through the public API
4. stage EL2809 outputs through the public API
5. interact with the ring through the real UDP transport path

The hardware variant exercises the same ring shape on a real bus and is
excluded by default. Enable it with:

```bash
ETHERCAT_INTERFACE=enp0s31f6 mix test --include hardware test/integration/hardware/ring_test.exs
```

The simulator itself is also covered by unit-level and subsystem-level tests
under `test/ethercat/simulator/` and related simulator-focused test files.

The integration scenario loop under
[`test/integration/simulator/`](/home/n0gg1n/Development/Work/opencode/ethercat/test/integration/simulator/)
now covers:

- `01` transient timeout through queued `:drop_responses`
- `02` WKC mismatch through queued `{:wkc_offset, delta}`
- `03` disconnect/reconnect through queued `{:disconnect, slave}`
- `04` UDP reply corruption, replay, and scripted transport faults
- `05` slave-local `SAFEOP` retreat with health polling
- `06` mailbox aborts in PREOP
- `07` combined fault scripts across timeout, WKC skew, and reconnect
- `08` delayed slave-local mutation after exchange-fault recovery
- `09` milestone-aware slave-local timing after healthy polls
- `10` segmented mailbox aborts during upload/download
- `11` reusable fault scripts with embedded milestone waits
- `12` startup mailbox abort during driver PREOP mailbox configuration
- `13` targeted logical-WKC skew without inventing slave-local faults
- `14` command-targeted WKC skew outside logical PDO traffic
- `15` mailbox milestone-timed segmented abort after successful segments
- `16` mailbox protocol-shape faults like bad counters or toggles
- `17` malformed mailbox response headers like wrong mailbox type or CoE service
- `18` malformed CoE payloads like truncated CoE headers or bad SDO commands
- `19` malformed segmented CoE upload responses like bad padding or segment commands
- `20` malformed segmented CoE download acknowledgements after partial or final progress
- `21` startup segmented-download acknowledgement faults during PREOP configuration
- `22` startup mailbox response timeouts during PREOP configuration
- `23` public mailbox response timeouts during segmented SDO upload/download
- `24` reconnect-time mailbox abort during PREOP rebuild without full-session restart
- `25` reconnect-time mailbox response timeouts during PREOP rebuild without
  full-session restart
- `26` reconnect-time malformed segmented-download acknowledgements during
  PREOP rebuild without full-session restart
- `27` reconnect-time malformed final segmented-download acknowledgements
  during PREOP rebuild, including committed-write semantics
- `28` reconnect-time PREOP fault scripts that fail once and self-heal on a
  later retry without manual simulator cleanup
- `29` reconnect-time PREOP fault scripts that retain different mailbox
  failures on successive retries before eventual recovery
- `30` reconnect-time mailbox PREOP degradation plus a later slave-local
  `SAFEOP` retreat during the same operational window

## Widget-Facing Signal API

The simulator now exposes a small signal-oriented API intended for higher-level
tools like a `kino_ethercat` simulator widget.

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
talk to the simulator end to end.
If you supervise `EtherCAT.Simulator` as a child, `child_spec/1` now follows
the same supervised path as `start/1`, including `udp: [...]`.
Stop the simulator runtime with `stop/0`.

`EtherCAT.Simulator.info/0` now exposes queued fault state through:

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

That keeps the API generic enough for a UI widget without tying it to a
specific device profile or driver callback contract.

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
- explicit cross-slave wiring via
  `EtherCAT.Simulator.Slave.connect/2`
- real-device hydration through:
  - `EtherCAT.Simulator.Slave.from_driver/2`

## Current General-Slave Coverage

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

## Fault API Split

Use the runtime-side API when the fault should affect datagram semantics or
slave availability:

```elixir
alias EtherCAT.Simulator.Fault

EtherCAT.Simulator.inject_fault(
  Fault.drop_responses()
  |> Fault.next(10)
)

EtherCAT.Simulator.inject_fault(
  Fault.wkc_offset(-1)
  |> Fault.next(6)
)

EtherCAT.Simulator.inject_fault(
  Fault.command_wkc_offset(:fprd, -1)
  |> Fault.next(30)
)

EtherCAT.Simulator.inject_fault(
  Fault.logical_wkc_offset(:outputs, -1)
  |> Fault.next(6)
)

EtherCAT.Simulator.inject_fault(
  Fault.script([Fault.drop_responses(), Fault.disconnect(:outputs)])
)

EtherCAT.Simulator.inject_fault(
  Fault.retreat_to_safeop(:outputs)
  |> Fault.after_ms(250)
)

EtherCAT.Simulator.inject_fault(
  Fault.retreat_to_safeop(:outputs)
  |> Fault.after_milestone(Fault.healthy_polls(:outputs, 10))
)

EtherCAT.Simulator.inject_fault(
  Fault.mailbox_abort(:mailbox, 0x2003, 0x01, 0x0800_0000, stage: :upload_segment)
  |> Fault.after_milestone(Fault.mailbox_step(:mailbox, :upload_segment, 2))
)

EtherCAT.Simulator.inject_fault(
  Fault.mailbox_protocol_fault(:mailbox, 0x2003, 0x01, :upload_segment, :toggle_mismatch)
)

EtherCAT.Simulator.inject_fault(
  Fault.mailbox_protocol_fault(:mailbox, 0x2001, 0x01, :upload_init, {:coe_service, 0x02})
)

EtherCAT.Simulator.inject_fault(
  Fault.mailbox_protocol_fault(:mailbox, 0x2001, 0x01, :upload_init, :invalid_coe_payload)
)

EtherCAT.Simulator.inject_fault(
  Fault.mailbox_protocol_fault(:mailbox, 0x2003, 0x01, :upload_segment, :invalid_segment_padding)
)

EtherCAT.Simulator.inject_fault(
  Fault.script([
    Fault.drop_responses(),
    Fault.wait_for(Fault.healthy_polls(:outputs, 10)),
    Fault.retreat_to_safeop(:outputs)
  ])
)
```

Use the UDP-side API when the fault should corrupt raw replies at the transport
edge:

```elixir
alias EtherCAT.Simulator.Udp.Fault, as: UdpFault

EtherCAT.Simulator.Udp.inject_fault(UdpFault.truncate())
EtherCAT.Simulator.Udp.inject_fault(UdpFault.wrong_idx() |> UdpFault.next(2))

EtherCAT.Simulator.Udp.inject_fault(
  UdpFault.script([UdpFault.unsupported_type(), UdpFault.replay_previous()])
)
```

That boundary matters:

- `EtherCAT.Simulator` owns datagram/runtime behavior
- `EtherCAT.Simulator.Udp` owns malformed, stale, or mismatched raw replies
- both builder modules expose `describe/1` for widget-facing labels

## Remaining Intentional Limits

The simulator still does **not** try to model everything.

Current intentional limits:

- no raw-socket simulator endpoint yet
- no carrier/link-loss simulation below the protocol layer
- no full motion physics for drives
- no complete SDO Info service surface
- no attempt to mirror SOES internal control flow one-to-one

Those are deliberate scope limits. The simulator is meant to be a deterministic
protocol and device-behavior test tool, not a full field-device firmware stack.

## Completed Generalization Work

The simulator generalization plan is now implemented end to end. The historical
plan record lives at:

- [docs/exec-plans/completed/simulator-generalization.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/simulator-generalization.md)

## EEPROM / SII Strategy

The EEPROM image is device-owned.

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

## Integration Test Philosophy

Integration tests now target the real runtime against a driver-backed simulated
ring.

The simulator remains a library feature for:

- unit and subsystem testing
- local tooling and widgets
- deterministic protocol experiments
- ring-shaped deep integration coverage built from real drivers

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

## Completed Milestone Coverage

The original simulator milestones are now all covered:

- Milestone 1
  - one static digital I/O slave
  - real UDP loopback transport
  - boot to `:operational`
  - cyclic I/O roundtrip
- Milestone 2
  - multiple slaves in one simulator
  - realistic startup count and station assignment behavior
  - multi-slave logical image coverage
- Milestone 3
  - expedited and segmented CoE upload/download
  - deterministic SDO values
  - PREOP mailbox integration tests
  - mailbox abort replies
- Milestone 4
  - explicit fault injection for:
    - no response
    - wrong WKC
    - slave disconnect / reconnect
    - AL error latch
    - retreat to `SAFEOP`
    - mailbox abort replies
    - delayed and milestone-triggered slave-local faults
  - deep recovery tests through the real UDP transport

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
