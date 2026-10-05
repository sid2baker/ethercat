# Rules for working with EtherCAT

EtherCAT is an experimental pure-Elixir EtherCAT master. Read the module docs for
this dependency version before using it; unreleased `main` and published versions
may have different APIs.

## Runtime ownership

- Supervise one `EtherCAT.Runtime` per BEAM node in the host application.
- `EtherCAT.start/1` returns `{:ok, session}`. Carry that `EtherCAT.Session` through
  runtime, provisioning, diagnostic, subscription, and capture calls.
- `EtherCAT.stop/1` ends the session, not the host supervisor. Do not reuse stopped
  sessions; they return `{:error, :stale_session}`.
- Use an explicit `:backend` (`EtherCAT.Backend`). Physical rings use raw Ethernet;
  UDP is the simulator/integration transport, not a physical ESC transport.

## Startup and observations

- Without a slave list, discovery holds the ring in PREOP. Use
  `EtherCAT.await_ready/2`, not `await_operational/2`, for this workflow.
- Cyclic I/O requires ordered `EtherCAT.Slave.Config` entries and
  `EtherCAT.Domain.Config` entries. Domain periods are whole milliseconds, expressed
  in microseconds. Use `await_operational/2` after requesting cyclic operation.
- `EtherCAT.Provisioning` owns PREOP configuration, activation/deactivation, and SDOs.
  `EtherCAT.Diagnostics` owns detailed runtime inspection.
- `EtherCAT.sample/3` returns a coherent per-slave, per-domain observation; there is
  no cross-domain consistency guarantee. Check `Sample.errors` for decode failures.
  A retained sample alone is not proof that the ring is currently healthy.
- `EtherCAT.subscribe/3` returns `{:ok, ref, status, samples}` and pushes
  `{:ethercat, ref, payload}` with no backpressure. Poll `samples/2` for latest-only
  consumers. `EtherCAT.Signals` is the specialist signal/latch subscription API.
- `EtherCAT.write/4` stages an output; `:ok` is not proof of physical actuation.
  Never hide transport, WKC, AL-state, or topology faults with optimistic state.

## Drivers and tests

- Implement `EtherCAT.Driver`, not a slave-runtime behaviour. `signal_model/2`
  maps named signals onto discovered PDOs; `describe/1` is static/offline metadata.
- Codecs return `{:ok, value}` / `{:error, reason}`. Encoding must match the declared
  width and zero unused high bits. Only registered directions require codecs.
- Use `EtherCAT.Driver.Provisioning` for optional mailbox/sync configuration and
  `EtherCAT.Simulator.Adapter` for separate simulator definitions. Device identity
  metadata is not automatic hardware compatibility enforcement.
- Start with deterministic `EtherCAT.Simulator` tests. Raw-socket and hardware tests
  need explicit interface setup and privileges; never run them on a production ring.
- Distributed Clocks synchronize device clocks; they do not make BEAM scheduling
  hard real-time or guarantee that PDO frames arrive before a device deadline.
