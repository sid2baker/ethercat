# Simulator Testing

## Integration Coverage

Repository integration coverage has two maintained variants built around the
same real drivers:

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

For the maintained scenario catalog and authoring loop, use:

- [`test/integration/simulator/README.md`](/home/n0gg1n/Development/Work/opencode/ethercat/test/integration/simulator/README.md)
- [`test/integration/hardware/README.md`](/home/n0gg1n/Development/Work/opencode/ethercat/test/integration/hardware/README.md)

That is the canonical place for the numbered scenario list. This file stays at
the simulator-subtree level and summarizes the testing philosophy instead of
duplicating every scenario note.

Current scenario families covered by the simulator suite include:

- transient timeouts and dropped replies
- UDP reply corruption, replay, and stale-frame style transport faults
- WKC mismatch, command-targeted skew, and logical-slave-targeted skew
- slave disconnect/reconnect and `SAFEOP` retreat
- startup mailbox failures during PREOP configuration
- public SDO upload/download mailbox protocol faults
- reconnect-time PREOP rebuild failures without full-session restart
- telemetry-triggered chained recovery follow-ups
- captured real-device cases such as `EL3202` reconnect and decode recovery

## Integration Test Philosophy

Integration tests target the real runtime against a driver-backed simulated
ring.

The simulator remains a library feature for:

- unit and subsystem testing
- local tooling and widgets
- deterministic protocol experiments
- ring-shaped deep integration coverage built from real drivers

Real hardware should complement this, not replace it:

- simulator scenarios cover deterministic fault matrices that are hard to
  trigger safely or repeatably on a bench
- captured real-device fixtures keep simulator coverage anchored in realistic
  startup and PDO semantics
- hardware runs are still useful for smoke tests, capture generation, and
  simulator-drift checks

## Scenario Granularity

Prefer one simulator scenario per behavioral regression.

Share ring builders, helpers, and assertions aggressively, but keep distinct
fault stories in separate files so failures localize cleanly. Combine tests
only when the behavior under test is the same and only the malformed response
shape or small input variant changes.

## Fixture Tiers

Not every simulator scenario should use the same kind of virtual slave.

Use synthetic fixture drivers when the goal is protocol isolation:

- `ConfiguredMailboxDevice`
- `SegmentedConfiguredMailboxDevice`
- `ConfiguredProcessMailboxDevice`

Those are the right choice for mailbox fault matrices, reconnect PREOP rebuild
coverage, and mixed-fault choreography where device semantics should stay as
small as possible.

Use captured or hand-curated real-device fixtures when the goal is realistic
device shape:

- `EL3202`
- the digital I/O ring built from `EK1100`, `EL1809`, and `EL2809`

Those fixtures should exercise realistic startup SDOs, PDO naming, and decode
behavior while still keeping the test deterministic and simulator-friendly.

Use hardware tests for the final complement, not as the only integration path:

- smoke validation on a real bus
- capture generation
- simulator drift detection

If a fault must be induced precisely, repeatedly, or unsafely for bench
hardware, it belongs in the simulator suite first.

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
