# Plan: Refactor Roadmap

## Status

ACTIVE

## Goal

Provide a clear refactor order for turning the library into a more spec-aligned,
BEAM-native EtherCAT master without reopening already-settled boundaries.

The target architecture is:

1. `Master` owns initial intent, session orchestration, and recovery policy
2. `Domain`, `DC`, and `Slave` own their live runtime state
3. public APIs expose intent and live status, not internal address-planning or
   process wiring details
4. deviations from the EtherCAT model remain deliberate, documented, and small

This is an ordering document. The earlier SyncManager/domain and Distributed
Clocks child plans have now moved to `completed/`.

## Already Landed

These are no longer the main refactor targets:

1. registry-based runtime identity instead of cached slave pids
2. master-owned logical address planning for high-level domain config
3. split `{domain, SyncManager}` attachment support
4. coherent split-output staging
5. live-owned domain cycle-time updates with master plan kept immutable
6. explicit runtime structs for `Bus` and `DC`

The roadmap below focuses on what still needs cleanup or completion.

## Structural Note

`Master` and `Slave` are still carrying too much behavior inline. The protocol
complexity is real and expected. The current concentration of that complexity
inside ~2000-line modules is not.

The roadmap below now treats runtime-module decomposition as explicit work, not
an incidental cleanup.

## Design Rules

1. Spec first. Use EtherCAT semantics as the default model.
2. BEAM fault tolerance is an implementation strength, not a semantic
   replacement for the spec.
3. Initial config and live runtime are different objects. Keep that split
   explicit.
4. Refactors should remove leaks from the public API before adding new feature
   surface.
5. No giant rewrite. Land in phases that keep the hardware examples usable.

## Execution Order

## Phase Status Snapshot

1. Phase 1 — COMPLETE
2. Phase 2 — COMPLETE
3. Phase 3 — COMPLETE for the current library line; remaining richer DC work is tracked as debt/future work
4. Phase 4 — ACTIVE
5. Phase 5 — PENDING
6. Phase 6 — PENDING
7. Phase 7 — PENDING

## Phase 1 - Finish master-owned runtime recovery

### Goal

Make runtime recovery fully master-owned and explicit instead of being a partial
extension of startup/degraded handling.

### Status

COMPLETE

### Why first

This is the main remaining architectural risk. It affects the correctness of
disconnect handling, domain stop/crash recovery, and the meaning of public phase
reporting.

### Changes

1. introduce an explicit recovery sub-phase or state owned by `Master`
2. unify runtime fault inputs:
   - domain invalid/stopped/crashed
   - slave down/crashed/retreated
   - DC runtime loss or lock-policy failure
3. let the master decide between:
   - selective affected-domain reopen/rebuild
   - controlled full-session restart as the fallback
4. keep slave reconnect authorization master-owned; slaves may detect faults but
   must not independently decide to rebuild shared cyclic resources
5. make `phase/0`, `await_running/1`, and `await_operational/1` reflect runtime
   recovery truthfully

### Exit Criteria

1. reconnect, domain-stop, and DC-loss paths all go through one recovery policy
2. public phase reporting distinguishes startup, operational, and recovery
3. the master plan stays immutable while child runtimes own live state

### Notes

This work is already landed in the runtime:

1. public `:recovering` phase exists
2. runtime domain/slave/DC faults route through one master-owned recovery policy
3. child runtimes own live state while the master retains the initial plan

## Phase 2 - Close the remaining process-data alignment work

### Goal

Finish the remaining work from the SyncManager/domain refactor and remove the
last library-shaped shortcuts from the process-data model.

### Status

COMPLETE

### Why second

The core attachment model is already in place. The remaining work should be
finished before more feature work piles on top of it.

### Changes

1. prove reconnect/recovery correctness for multi-attachment slaves after the
   master-owned recovery refactor
2. review whether any remaining runtime indexes or caches are still keyed too
   narrowly for attachment-aware recovery
3. either implement bit-level packing or explicitly keep byte-level packing as
   a documented non-goal for the current line
4. make maintained examples and docs use split-domain layouts as the normal
   reference examples, not the special case

### Exit Criteria

1. split-SM configs are covered in examples, tests, and recovery scenarios
2. no public docs imply the old one-SM-one-domain model

### Notes

This phase is complete for the current library line. The detailed execution work
moved to:

- [docs/exec-plans/completed/syncmanager-domain-spec-alignment.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/syncmanager-domain-spec-alignment.md)

## Phase 3 - Complete Distributed Clocks and sync semantics

### Goal

Finish the remaining Distributed Clocks refactor so DC behavior and public API
match the spec/reference-master model more closely.

### Status

COMPLETE FOR CURRENT LINE

### Why third

DC now has the right broad shape, but several important pieces remain incomplete
for drives and richer timing use cases.

### Changes

1. add maintained hardware validation for at least one sync-sensitive slave
   that really needs `0x1C32` / `0x1C33`
2. surface redundancy/DC runtime status as a first-class public status surface
3. extend topology/delay handling beyond the current linear-chain assumption
4. tighten docs so the stack promises hardware-side alignment, not sub-ms BEAM
   scheduling guarantees

### Exit Criteria

1. maintained hardware examples cover both simple DC I/O and at least one
   sync-sensitive CoE-mode slave
2. drives that require CoE sync-mode configuration have a clean integration path
3. DC runtime loss feeds the same lifecycle policy as other cyclic faults

### Notes

The main DC alignment work is complete for the current library line and moved
to:

- [docs/exec-plans/completed/distributed-clocks-spec-alignment.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/distributed-clocks-spec-alignment.md)

Remaining richer DC work stays visible as debt/future work rather than blocking
the roadmap:

1. maintained hardware validation for sync-sensitive CoE-mode slaves
2. richer redundancy/public status surfacing
3. non-linear topology delay handling

## Phase 4 - Decompose oversized runtime modules

### Goal

Reduce `Master`, `Slave`, and `Domain` to clearer runtime shells with extracted
protocol collaborators.

### Why fourth

The architecture is now correct enough that structural decomposition will pay
off. Without this step, every remaining feature/refactor continues to pile onto
large mixed-concern modules.

### Changes

1. extract `Master` startup / activation / recovery / session helpers
2. extract `Slave` bootstrap / process-data / mailbox / DC / transition helpers
3. extract dense `Domain` cycle / image / diagnostics helpers while keeping one
   runtime process module
4. keep `gen_statem` shell modules focused on state ownership and event routing
5. document the new subsystem boundaries

Detailed execution plan:

- [docs/exec-plans/active/runtime-module-decomposition.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/active/runtime-module-decomposition.md)

### Exit Criteria

1. `Master` and `Slave` are no longer giant mixed-concern runtime modules
2. `Domain` remains one concern but with extracted hot-path helpers
3. protocol behavior stays intact while module boundaries become clearer

## Phase 5 - Harden the domain data plane

### Goal

Make the domain hot path stricter, more observable, and safer under load.

### Why fifth

The architecture should be decomposed before optimizing or enriching the hot
path. Once the shells and helpers are clearer, the remaining domain gaps become
easier to evaluate in isolation.

### Changes

1. keep per-PDO freshness timestamps so applications can detect stale values
2. decide whether input fan-out needs an explicit overload policy
3. keep the max-frame/image-size guard explicit and covered
4. review invalid-cycle behavior so "hold last safe image" semantics are
   consistent and documented
5. decide whether domain writes should grow a stronger batching or sampling API,
   or whether raw ETS staging remains the intended boundary

### Exit Criteria

1. domain info and telemetry can explain data freshness and misses
2. hot-path behavior under overload is explicit instead of accidental
3. the domain module has a crisp documented contract for valid vs invalid cycles

## Phase 6 - Clean the public surface and generated examples

### Goal

Make the user-facing API and examples reflect the architecture that now exists,
not the history of how the implementation got there.

### Why sixth

Several internal leaks have already been removed. This phase finishes that
cleanup and keeps examples and tooling from reintroducing stale patterns.

### Changes

1. audit example scripts, example templates, and diagnostics panels for stale config
   fields and outdated lifecycle assumptions
2. standardize how live-vs-initial state is described in docs:
   - domain timing
   - DC runtime status
   - slave runtime identity
3. keep public config intent-focused and push expert/low-level controls down to
   low-level modules only
4. add a stable public "supported telemetry events" story around
   `EtherCAT.Telemetry.events/0`
5. either implement or remove stale harness/docs references such as missing Mix
   tasks

### Exit Criteria

1. README, examples, and diagnostics surfaces all use the same mental model
2. user-facing docs no longer expose removed internal details
3. generated/starter code does not reintroduce deprecated patterns

## Phase 7 - Raise the validation bar

### Goal

Turn hardware validation from ad-hoc manual confidence into a maintained part of
the project workflow.

### Why last

The earlier phases change semantics and structure. Validation should harden once
the intended architecture has settled.

### Changes

1. define a maintained smoke matrix for examples:
   - scan
   - multi-domain
   - fault tolerance
   - DC sync
2. add a local hardware-validation runner or harness that reflects the current
   maintained examples
3. promote the most valuable real-hardware regressions into repeatable checks
4. document the tested hardware envelope and known host/runtime limits

### Exit Criteria

1. hardware regressions have a maintained execution path, not just tribal memory
2. docs match what is actually exercised on the live ring
3. future refactors have a repeatable hardware confidence loop

## Things Not To Fold In Right Now

These may become future projects, but they should not be bundled into the
roadmap above:

1. a sub-millisecond scheduler rewrite for `Domain`
2. a broad motion-control or drive-profile layer
3. speculative protocol features without a maintained hardware example
4. large public API expansion before the current boundaries are stable

## Recommended Next Move

Start with Phase 4.

The next highest-leverage change is structural decomposition of `Master`,
`Slave`, and `Domain` now that the lifecycle, SyncManager/domain, and DC
ownership refactors have landed.
