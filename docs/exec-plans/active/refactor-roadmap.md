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

This is an ordering document. Detailed execution for some topics already lives
in child plans:

- `docs/exec-plans/active/syncmanager-domain-spec-alignment.md`
- `docs/exec-plans/active/distributed-clocks-spec-alignment.md`

## Already Landed

These are no longer the main refactor targets:

1. registry-based runtime identity instead of cached slave pids
2. master-owned logical address planning for high-level domain config
3. split `{domain, SyncManager}` attachment support
4. coherent split-output staging
5. live-owned domain cycle-time updates with master plan kept immutable
6. explicit runtime structs for `Bus` and `DC`

The roadmap below focuses on what still needs cleanup or completion.

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

## Phase 1 - Finish master-owned runtime recovery

### Goal

Make runtime recovery fully master-owned and explicit instead of being a partial
extension of startup/degraded handling.

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

## Phase 2 - Close the remaining process-data alignment work

### Goal

Finish the remaining work from the SyncManager/domain refactor and remove the
last library-shaped shortcuts from the process-data model.

### Why second

The core attachment model is already in place. The remaining work should be
finished before more feature work piles on top of it.

### Changes

1. refresh `syncmanager-domain-spec-alignment.md` so it reflects what already
   landed and what still remains
2. prove reconnect/recovery correctness for multi-attachment slaves after the
   master-owned recovery refactor
3. review whether any remaining runtime indexes or caches are still keyed too
   narrowly for attachment-aware recovery
4. either implement bit-level packing or explicitly keep byte-level packing as
   a documented non-goal for the current line
5. make maintained examples and docs use split-domain layouts as the normal
   reference examples, not the special case

### Exit Criteria

1. the SyncManager/domain plan can move to `completed/`
2. split-SM configs are covered in examples, tests, and recovery scenarios
3. no public docs imply the old one-SM-one-domain model

## Phase 3 - Complete Distributed Clocks and sync semantics

### Goal

Finish the remaining Distributed Clocks refactor so DC behavior and public API
match the spec/reference-master model more closely.

### Why third

DC now has the right broad shape, but several important pieces remain incomplete
for drives and richer timing use cases.

### Changes

1. finish the active DC alignment plan:
   - CoE sync-mode objects `0x1C32` / `0x1C33`
   - remaining SYNC1/latch cleanup
   - docs/tooling cleanup around startup `await_lock?` vs runtime `lock_policy`
2. surface redundancy/DC runtime status as a first-class public status surface
3. extend topology/delay handling beyond the current linear-chain assumption
4. tighten docs so the stack promises hardware-side alignment, not sub-ms BEAM
   scheduling guarantees

### Exit Criteria

1. the active DC plan can move to `completed/`
2. drives that require CoE sync-mode configuration have a clean integration path
3. DC runtime loss feeds the same lifecycle policy as other cyclic faults

## Phase 4 - Harden the domain data plane

### Goal

Make the domain hot path stricter, more observable, and safer under load.

### Why fourth

The architecture should be correct before optimizing or enriching the hot path.
Once lifecycle and DC ownership are settled, the remaining domain gaps become
easier to evaluate in isolation.

### Changes

1. add per-signal or per-PDO freshness timestamps so applications can detect
   stale values
2. add a backpressure policy for input fan-out to slow slave processes
3. keep the max-frame/image-size guard explicit and covered
4. review invalid-cycle behavior so "hold last safe image" semantics are
   consistent and documented
5. decide whether domain writes should grow a stronger batching or sampling API,
   or whether raw ETS staging remains the intended boundary

### Exit Criteria

1. domain info and telemetry can explain data freshness, misses, and fan-out loss
2. hot-path behavior under overload is explicit instead of accidental
3. the domain module has a crisp documented contract for valid vs invalid cycles

## Phase 5 - Clean the public surface and generated examples

### Goal

Make the user-facing API and examples reflect the architecture that now exists,
not the history of how the implementation got there.

### Why fifth

Several internal leaks have already been removed. This phase finishes that
cleanup and keeps notebooks/examples from reintroducing stale patterns.

### Changes

1. audit Livebooks, example templates, and diagnostics panels for stale config
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

1. README, examples, and Livebooks all use the same mental model
2. user-facing docs no longer expose removed internal details
3. generated/starter code does not reintroduce deprecated patterns

## Phase 6 - Raise the validation bar

### Goal

Turn hardware validation from ad-hoc manual confidence into a maintained part of
the project workflow.

### Why last

The earlier phases change semantics. Validation should harden once the intended
architecture has settled.

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

Start with Phase 1 and carve it into a focused child plan:

- master-owned recovery state/sub-phase
- affected-domain rebuild policy
- slave reconnect authorization
- DC runtime fault integration

That is the highest-leverage refactor left in the stack.
