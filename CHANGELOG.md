# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `36ed6b8`, `eee9d1e`, `a4b947b` — `EtherCAT.Simulator` now supports raw-socket transport, redundant dual-ingress raw topologies, and shared UDP/raw transport fixtures for integration and hardware bring-up.
- `c4a6621`, `1f2b526`, `b12eec5` — integration coverage now includes event-triggered reconnect/disconnect mixes, harder clustered recovery chains, and split-domain EL3202 reconnect scenarios.
- `80dc840`, `c42b0c9` — bus and hardware tooling now expose richer runtime diagnostics plus loopback and hardening knobs for real hardware bring-up.
- `93c864d`, `6516c23`, `4a3321b`, `8eff41c` — GitHub Actions now cover CI and release automation, including raw-capable runners, raw simulator setup, and tag-build verification.

### Changed
- `4ae4392`, `0248012`, `8eff41c` — public master/domain/slave query paths are normalized, root API contracts are clearer, and synchronous calls now return `{:error, {:server_exit, reason}}` when a local server dies mid-call instead of exiting the caller.
- `04b2c5f`, `072119d`, `9b3b4ba`, `dad947e`, `8eff41c` — simulator and helper/reference guidance was consolidated into source-adjacent docs and local-only helper material so the tracked repo surface stays focused on maintained implementation docs.
- `8eff41c` — capture snapshots now write portable `.capture` data files instead of executable Elixir source, and generated simulator scaffolds load those data-only artifacts safely.
- `b57763a` — telemetry and logging now follow a stricter observability contract: transaction spans use stable stop metadata, link/frame events distinguish aggregate links from concrete endpoints, repeated startup/recovery retries are less noisy in logs, and new DC runtime plus slave-startup retry events improve machine-readable introspection.
- `af5192e` — telemetry now separates invalid domain cycles from transport misses, master startup/activation/DC-lock decisions emit bounded lifecycle events, slave fault/down signals carry richer detail, and long-lived master/bus/domain/DC/slave/simulator processes now stamp consistent structured metadata onto high-signal logs.

### Fixed
- `95f343d` — DC recovery and configuration validation are stricter, reducing invalid recovery paths and catching bad setup earlier.
- `c937d53` — redundant transport now merges split logical replies correctly.
- `d852fd4` — bus transaction aging semantics and diagnostics are now more explicit during retry and timeout handling.
- `7055878` — raw socket transport no longer drains buffered frames on idx-mismatch rearm, preventing legitimate responses from being lost when rogue EtherCAT traffic is present on the wire.
- `1b2211f` — redundant link rejoin now drains a reopened port, honors explicit carrier-restore notifications, and only promotes the restored leg after a run of successful probe cycles so cyclic traffic does not stall when a healthy backup path is already carrying the ring.
- `(pending hash)` — the bus runtime now executes built-in single and redundant traffic exclusively through `Bus.Circuit`, the legacy `Bus.Link` path is gone, OS link state is no longer part of bus correctness, and `Bus.info/1` reports smoothed topology/fault assessment from observed exchange results rather than carrier-driven healing state.

### Docs
- `8f773d6`, `c42b0c9`, `0248012`, `04b2c5f`, `072119d`, `9b3b4ba`, `ee210fa`, `8eff41c` — README, hardware playbooks, simulator docs, and API guidance were rewritten to better explain transport boundaries, bring-up workflow, release metadata, and fault/recovery scenarios.

## [0.3.1] - 2026-03-12

### Added
- `mix docs.fresh` now forces recompilation before docs generation so external moduledoc source files are picked up reliably
- `EtherCAT.Capture` now supports an interactive slave capture workflow and can generate richer integration support drivers from captured SDO and PDO data
- Real-hardware scripts and helpers now live under `test/integration/hardware/`, alongside shared hardware support and a captured EL3202 support driver

### Changed
- Generated capture drivers now include mailbox startup configuration and device-specific templates such as the EL3202 typed decode path when captured data is available
- Simulator scenario helpers now support deterministic event-triggered follow-up faults, and simulator docs now explain fixture tiers, real-vs-virtual hardware use, and the UDP transport boundary more directly
- Hardware examples were folded into the maintained integration suite so the old `examples/` tree could be removed

### Fixed
- Master recovery now replaces stale critical disconnect faults with reconnect-time PREOP configuration failures for PDO-participating slaves, allowing later recovery retries to return the master to `:operational`
- Telemetry-triggered scenario faults now inject synchronously, which makes event-driven simulator scenarios deterministic instead of eventually consistent
- Generated docs no longer warn about public moduledocs referencing hidden internal helper modules

### Docs
- Simulator moduledocs and README now explain that the UDP simulator is a virtual slave segment for testing, not a raw-wire EtherCAT NIC replacement
- Root project guidance now points hardware-script users at `MIX_ENV=test`, and markdown guidance drift around release/dev docs was cleaned up

## [0.3.0] - 2026-03-12

### Changed
- Bus link monitoring now uses the internal netlink/sysfs implementation instead of an external interface-management dependency
- Master recovery now gates stopped-domain restart on live carrier state and logs explicit carrier loss/restore events
- Runtime state-machine modules (`Master`, `Slave`, `Domain`, `DC`) were further reduced to state-machine boundaries with helper facades
- `EtherCAT.Slave.Driver` now uses `signal_model/1,2`, and simulator-specific authoring moved out of the real driver behaviour into optional `MyDriver.Simulator` companions via `EtherCAT.Simulator.DriverAdapter`
- `EtherCAT.Simulator` now exposes builder-style runtime fault injection with queued, delayed, and milestone-triggered scripts plus richer signal/snapshot surfaces for tooling

### Fixed
- Public `Master` API calls now return `{:error, :timeout}` when the local master call itself times out instead of exiting the caller
- Real carrier loss now stops domains immediately on confirmed `:down`, without domain restart churn while the cable is still unplugged
- Maintained hardware scripts were refreshed for the current runtime and bus/link-monitor implementation
- `await_running/1` and `await_operational/1` now tolerate a small local reply grace window so terminal startup results do not get masked by near-boundary call timeouts
- Activation now blocks immediately on PREOP configuration failures instead of starting OP activation work for unrelated slaves

### Docs
- The README driver example now matches the current `signal_model/1` callback, and the project landing page uses the Kino smart-cell setup screenshot
- Simulator docs and integration scenario notes now cover the current fault builder API, mailbox protocol fault coverage, and delayed/milestone scheduling

## [0.2.0] - 2026-03-09

### Added
- Dynamic PREOP-first startup and configuration flow for discovered slaves
- Master-owned logical window allocation for high-level domain configs
- Split `{domain, SyncManager}` attachment support, including split-SM diagnostics
- Explicit runtime fault recovery with `:recovering` state and targeted slave fault tracking
- Input freshness timestamps via `read_input/2 -> {:ok, {value, updated_at_us}}`
- Public telemetry event enumeration via `EtherCAT.Telemetry.events/0`
- Richer runtime diagnostics for slaves, domains, and DC status

### Changed
- Public lifecycle is now exposed through `EtherCAT.state/0`
- `EtherCAT.Domain.Config` no longer accepts `logical_base`; the master allocates it
- Master, Slave, Domain, and DC runtime boundaries were decomposed into smaller internal modules
- Slave internals are grouped under clearer runtime, process-data, mailbox, and ESC namespaces
- Automatic bus frame-timeout tuning now uses a safer host-jitter floor on slower cycles

### Fixed
- Reconnect and recovery paths now preserve split attachment semantics and restart stopped domains
- `test/integration/hardware/scripts/el3202.exs` and `test/integration/hardware/scripts/sdo_debug.exs` now work against the current driver/runtime contract
- Hardware fault-tolerance examples now match the current recovery model
- Polling callers regain access to cached PDO freshness metadata

### Docs
- README and moduledocs now reflect the actual runtime state machines and current API
- Completed refactor and spec-alignment plans were closed and moved out of active execution

## [0.1.0] - 2026-03-07

### Added
- Pure-Elixir EtherCAT master runtime over standard Ethernet (raw socket + UDP transport)
- Declarative bus configuration via `EtherCAT.start/1` with `Slave.Config` and `Domain.Config`
- Cyclic process data exchange — self-timed LRW domain cycling with drift-compensated scheduling
- CoE SDO transfers (expedited and segmented) for mailbox-based slave configuration
- Distributed clocks support (`EtherCAT.DC.Config`) with automatic reference clock selection
- Subscribe-on-change signal API: `subscribe/2`, `read_input/2`, `write_output/3`
- `EtherCAT.Slave.Driver` behaviour for custom PDO encode/decode per device type
- Default auto-discovery driver for unknown slaves via SII EEPROM PDO scan
- `slave_info/1`, `domain_info/1`, `slaves/0`, `domains/0` introspection API
- Telemetry events for domain cycle done/missed
- Bus redundancy link support
