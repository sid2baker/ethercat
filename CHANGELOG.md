# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Startup-held `:preop_ready` sessions no longer let the default `250ms`
  slave health poll mark disconnected PREOP-held slaves `:down` and push the
  master into `:recovering` (`473e224`).

### Changed
- The public runtime surface now names the managed instance consistently as a
  slave: `EtherCAT.slaves/0`, `snapshot.slaves`, `%EtherCAT.SlaveSnapshot{}`,
  and `%EtherCAT.Event{slave: ...}` replace the old mixed device/slave naming
  (`f15d37b`).
- `EtherCAT` is now the only normal public runtime entry point: `slaves/0`,
  `snapshot/0`, `snapshot/1`, `describe/1`, `subscribe/2`, and `command/3`
  expose the driver-backed slave surface directly, and `EtherCAT.Device` is
  gone (`f15d37b`).
- `EtherCAT.Driver` was reduced to a smaller extension contract centered on
  `signal_model/2`, `project_state/4`, and `command/4`; mailbox setup and
  latch hooks now live under specialist behaviours, while optional simulator
  identity moved back onto the optional `identity/0` callback on
  `EtherCAT.Driver`, simulator companions
  use `EtherCAT.Simulator.Adapter`, and the extra simulator-side driver helper
  split was removed (`7830f13`).
- `EtherCAT.snapshot/0` now returns a best-effort aggregate of
  `%EtherCAT.SlaveSnapshot{}` structs instead of a flattened signal map, and
  `%EtherCAT.Event{}` is documented as the top-level driver/slave event
  envelope (`f15d37b`).
- Driver-backed commands now own the normal top-level write path, and command
  output staging emits public state-change events through the same `EtherCAT`
  subscription stream (`f15d37b`).
- Cyclic input refresh no longer decodes changed inputs twice: the slave runtime
  now computes changed input names from domain change notifications, samples and
  decodes inputs once during device-state refresh, and reuses that decoded image
  for both raw signal subscriptions and driver projection (`f15d37b`).
- The legacy `EtherCAT.Slave.Driver` compatibility shim is gone, and the
  built-in default driver implementation now lives in one place instead of
  splitting the implementation across extra slave-internal wrapper modules
  (`f15d37b`).

## [0.4.2] - 2026-03-19

### Fixed
- The release workflow now runs on OTP `28.1` so `mix hex.publish --dry-run`
  and release publishing no longer crash inside Hex's regex import path on
  GitHub runners (`e6fde6f`).

## [0.4.1] - 2026-03-19

### Fixed
- The release workflow now reads the package version without triggering a fresh
  compile during the tag check, so clean GitHub runners no longer fail `v*.*.*`
  releases with a false version mismatch (`b2de6f5`).

## [0.4.0] - 2026-03-19

### Added
- `EtherCAT.Simulator` now supports raw-socket transport, redundant dual-ingress
  raw topologies, and shared UDP/raw fixtures for integration and hardware
  bring-up (`36ed6b8`, `eee9d1e`, `a4b947b`).
- Integration coverage now includes event-triggered reconnect/disconnect mixes,
  clustered recovery chains, and split-domain EL3202 reconnect scenarios
  (`c4a6621`, `1f2b526`, `b12eec5`).
- Bus and hardware tooling now expose richer diagnostics plus loopback and
  hardening knobs for real-hardware bring-up (`80dc840`, `c42b0c9`).
- GitHub Actions now cover CI and release automation, including raw-capable
  runners, raw simulator setup, and tag-build verification (`93c864d`,
  `6516c23`, `4a3321b`, `8eff41c`).

### Changed
- Public master/domain/slave queries are more consistent, and synchronous calls
  now return `{:error, {:server_exit, reason}}` instead of exiting the caller
  when a local runtime dies mid-call (`4ae4392`, `0248012`, `8eff41c`).
- Simulator and helper guidance was consolidated into maintained source-adjacent
  docs, and generated capture snapshots now use portable data-only `.capture`
  files instead of executable Elixir (`04b2c5f`, `072119d`, `9b3b4ba`,
  `dad947e`, `8eff41c`).
- Version tags now publish the Hex package and HexDocs directly from CI instead
  of only creating a draft GitHub release (`29dcbd2`).
- Telemetry and structured logging are stricter and less noisy: invalid domain
  cycles are separated from transport misses, lifecycle decisions emit bounded
  machine-readable events, and long-lived processes stamp consistent metadata on
  high-signal logs (`b57763a`, `af5192e`).
- `EtherCAT.Master`, `EtherCAT.Slave`, `EtherCAT.Domain`, and `EtherCAT.DC`
  now own the public API directly, with internal `*.FSM` modules handling state
  transitions behind that boundary (`9f1342a`).
- Redundant-link timeout detail now emits bounded telemetry and recovery logs
  instead of warning on every repeated timeout pattern (`2d97faf`).
- Redundant-link `no_arrivals` timeout detail now stays in telemetry and
  generic frame-timeout warnings instead of emitting one-shot warning/cleared
  log pairs for transient blips (`cf4a90c`).
- Input reads now fail closed on stale cached PDO data, and simulator transport
  ownership is split cleanly under `EtherCAT.Simulator.Transport.*`
  (`11d1af2`).
- Raw AF_PACKET transport now suppresses local TX delivery with
  `PACKET_IGNORE_OUTGOING`; redundant links are raw-only in production, and
  degraded-port health no longer suppresses later send attempts on either leg.
  Reverse-path cross copies no longer complete exchanges ahead of the
  authoritative forward-path data, and completed exchanges now drain both
  legs before dispatching the next request to cut late-frame `idx_mismatch`
  drops (`cf4a90c`).
- Slave reconnect ownership is now simpler: `:down` slaves probe their stored
  scan position, reclaim an anonymous fixed station locally, and rebuild to
  PREOP themselves instead of waiting for master reconnect authorization or
  rediscovery fallback (`efbc8da`).

### Fixed
- DC recovery and configuration validation are stricter, catching bad setup
  earlier and reducing invalid recovery paths (`95f343d`).
- Raw simulator EEPROM reads now zero-pad out-of-range windows instead of
  crashing startup, which restores the healthy raw transport matrix path
  (`35ebde7`).
- Redundant transport now merges split logical replies correctly and reports
  degraded send failures as visible topology and link-health state
  (`c937d53`, `4b1ac0f`).
- Bus transaction aging, built-in circuit execution, and topology assessment are
  more explicit; the legacy `Bus.Link` execution path is gone and carrier state
  no longer drives bus correctness (`d852fd4`, `68f6c20`).
- Raw socket transport no longer drops legitimate replies on idx-mismatch rearm,
  and redundant rejoin now drains and reproves a restored leg before promoting
  it back into cyclic traffic (`7055878`, `1b2211f`).
- Failed activation now rolls back partially started DC/domain runtime,
  `Slave.subscribe/3` rejects unknown signal/latch names, and
  `Domain.write/read/sample` use explicit ETS lookup instead of exception-driven
  control flow (`4a9a4ad`).
- Default simulator/master runs no longer flap the whole session on isolated
  single-cycle misses: domains now escalate to master recovery only after a
  short unhealthy streak, while timeout tuning keeps a wider `5ms` floor on
  both the UDP simulator path and raw startup/activation traffic (`cf4a90c`).
- Redundant links now keep degraded one-sided bounce exchanges within the
  original frame-time budget instead of resetting them to a fresh fixed `25ms`
  merge timeout, so a `10ms` cyclic ring can keep running after
  secondary-port disconnect (`fea9d52`).
- Raw receive errors now surface through the bus transport boundary instead of
  being silently ignored, so a broken leg cannot leave single or redundant
  links stuck in `:awaiting` behind repeated socket-error chatter (`fea9d52`).
- Redundant realtime exchanges now complete immediately on a single processed
  bounce instead of waiting for merge-time timeout fallback, so `1ms` cyclic
  domains can stay healthy after backup-port disconnect (`52c4ae8`).
- Redundant realtime logical exchanges now keep a bounded merge window for
  complementary bounce replies before accepting a single processed bounce, so
  split-ring raw topology breaks merge back to full WKC instead of triggering
  false domain recovery (`1a80d39`).
- Redundant links now complete late degraded reliable one-sided bounces within
  the original frame budget, domain timeout-class misses stay stable even when
  queued realtime work expires, and the maintained redundant replug watcher now
  matches the current `Bus.info/1` link/topology surface (`7bfdb68`).
- Slaves held in `:preop` or `:safeop` now keep health polling active and
  still transition into recovery on disconnect or lower-state regressions
  instead of staying stranded in stale held states (`efbc8da`).

### Docs
- `ARCHITECTURE.md`, `README.md`, `RELEASE.md`, and simulator guidance were
  aligned to the current public/runtime boundaries, Hex publish workflow, and
  raw test interface ownership expectations (`b014f5d`).
- README, hardware playbooks, simulator docs, and API guidance were rewritten
  to better explain transport boundaries, bring-up workflow, release metadata,
  and fault/recovery scenarios (`8f773d6`, `c42b0c9`, `0248012`, `04b2c5f`,
  `072119d`, `9b3b4ba`, `ee210fa`, `8eff41c`).
- Public master, slave, domain, and DC moduledocs now live inline with their
  runtime modules, and the simulator integration README now reflects the
  current scenario set and fault-builder surface (`4a9a4ad`, `11d1af2`).

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
