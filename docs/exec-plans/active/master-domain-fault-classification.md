# Plan: Master and Domain Fault Classification Cleanup

## Status

ACTIVE

## Goal

Tighten the runtime fault model around `EtherCAT.Master` and
`EtherCAT.Domain` so that:

1. `EtherCAT.state/0` stays honest about the health of the cyclic runtime
2. slave-local faults are kept visible without over-driving the master state
3. `Domain` remains the source of truth for cyclic degradation
4. the current `Master` and `Domain` implementations become simpler while this
   behavior is clarified

This plan exists because the current split between `runtime_faults` and
`slave_faults` is directionally right, but still too coarse. In particular,
`slave_down` is currently treated as slave-local by default even though, for a
PDO-participating slave, it will often imply an invalid or stopped domain.

## Problem

The current runtime model has three overlapping signal sources:

1. `Domain` cycle results
   - WKC mismatch
   - transaction timeout
   - stopped cycling after consecutive misses
2. `Slave` health-poll / lifecycle events
   - retreated to `SAFEOP`
   - down / reconnected
   - crashed / PREOP recovery failure
3. `DC` runtime events
   - runtime failed
   - lock lost / regained

The implementation already treats domain/DC faults as state-driving and
slave-local faults as non-state-driving. The problem is that the current slave
classification is still too broad:

- some slave faults truly are local
- some are only *observations* and should wait for the domain to declare cyclic
  degradation
- some are effectively critical and should move the master into `:recovering`

That ambiguity leaks into both semantics and code shape:

- the public meaning of `:operational` is easy to misread
- `Master` has duplicated event handlers for stateful fault bookkeeping
- `Domain.Cycle` and `Master` each make part of the runtime fault decision

## Desired Model

The runtime should distinguish three fault classes explicitly.

### 1. Activation Faults

These block transition into OP but do not describe an already-operational
session losing its cyclic contract.

Examples:

- slave cannot be promoted to `:op`
- DC lock requirement is not satisfied during activation
- startup PREOP/OP sequencing fails

These remain `activation_failures` and drive `:activation_blocked`.

### 2. Critical Runtime Faults

These make the master unable to honestly report healthy cyclic runtime.

Examples:

- domain cycle invalid
- domain stopped / crashed
- DC runtime failed / crashed
- DC lock policy says lock loss is runtime-critical

These remain `runtime_faults` and drive `:recovering`.

### 3. Slave-Local Runtime Faults

These must stay visible, but they only drive the master state when they are
known to break the cyclic contract.

Examples:

- slave process crash while the physical slave and domain keep cycling
- slave retreats to `SAFEOP` but the domain WKC remains valid
- reconnect authorization / reconnect retry is in progress
- PREOP-only or mailbox-only slave has trouble while cyclic runtime is still
  valid elsewhere

These remain `slave_faults` and may coexist with `:operational`.

## Decision Rule

`Domain` should be the source of truth for cyclic degradation.

That implies:

1. `Master` should not treat every `slave_down` or `slave_retreated` event as
   automatically equivalent to cyclic degradation.
2. `Master` should only enter `:recovering` for slave faults when either:
   - the affected fault is intrinsically session-critical, or
   - a participating domain confirms invalid / stopped runtime.
3. A slave-local fault may remain visible while the master stays
   `:operational`, but only if the cyclic path is still healthy.

## Spec Alignment

This plan aligns to the protocol responsibilities summarized in:

- `docs/references/ethercat-spec/01-llm-reference-index.md`

Relevant areas:

- chapter 04: WKC as validity signal
- chapters 05-07: slave ESM / AL state observations
- chapter 20: continuous cyclic loop and invalid-cycle handling

The key alignment rule is:

- AL-state faults are important observations
- WKC / cycle validity still decide whether cyclic runtime is healthy

So the library should not collapse “slave not in OP” and “domain no longer
healthy” into the same thing unless the runtime evidence actually supports it.

## Simplification Targets

This is not just a semantic plan. It should also reduce code branching.

### Master

Simplify:

- duplicated `:operational` / `:recovering` slave-event handlers
- repeated `put fault -> maybe transition -> maybe schedule retry` patterns
- separate ad hoc logic for slave fault retry vs runtime retry

Target shape:

- one explicit classification helper for incoming slave faults
- one helper for “stay operational with visible slave fault”
- one helper for “enter recovering because the cyclic contract is broken”
- one helper for “resume operational once critical runtime faults are gone”

### Domain

Simplify:

- cycle result classification in `Domain.Cycle`
- duplicated “invalid response” vs “transport miss” bookkeeping shape
- notification boundaries between cycle bookkeeping and master-facing runtime
  fault signals

Target shape:

- one explicit cycle-result classifier:
  - `:valid`
  - `{:invalid_response, reason}`
  - `{:transport_miss, reason}`
- one shared cycle-fault recorder
- `Domain` remains the only process that decides whether the cyclic path is
  healthy, invalid, or stopped

## Execution Order

## Phase 1 - Lock the intended semantics in tests

### Goal

Make the desired master/domain/slave-fault contract explicit before changing
runtime behavior.

### Changes

1. Add or tighten master tests for:
   - `slave_retreated` while domain stays healthy
   - `slave_down` for a PDO-participating slave followed by domain invalid/stopped
   - slave process crash with domain still healthy
   - reconnect progression while master remains `:operational`
2. Add or tighten domain tests for:
   - WKC mismatch vs transport miss
   - state-driving notifications to `Master`
   - transition from invalid to healthy

### Exit Criteria

1. Tests clearly state which faults are slave-local and which are runtime-critical
2. Future refactors fail loudly if `:operational` becomes overly optimistic or
   overly pessimistic

## Phase 2 - Make fault classification explicit in Master

### Goal

Replace the current implicit classification spread across handlers with one
clear decision path.

### Changes

1. Add a dedicated classifier/helper module or helper section for:
   - activation faults
   - slave-local faults
   - critical runtime faults
2. Route slave events through that classifier instead of per-clause ad hoc
   decisions
3. Narrow `slave_down` handling so it is not treated as harmless by default
   without considering participation / follow-up domain health
4. Keep `slaves/0` as the public visibility surface for non-critical faults

### Exit Criteria

1. `Master` event handlers read as routing, not classification puzzles
2. `:operational` means “cyclic runtime healthy” and no more than that
3. The code no longer duplicates the same “put fault and maybe retry” pattern

## Phase 3 - Make Domain the clear cyclic-health authority

### Goal

Reduce ambiguity by centralizing cycle validity decisions in `Domain`.

### Changes

1. Add an explicit cycle-result classifier in `Domain.Cycle`
2. Keep the transport-miss threshold logic local to `Domain`
3. Ensure master-facing notifications stay at the right abstraction:
   - cycle invalid
   - cycle recovered
   - stopped
4. Remove any remaining ambiguity in how invalid responses vs misses contribute
   to state changes

### Exit Criteria

1. `Domain` is the only place that decides whether the cyclic path is healthy,
   invalid, or stopped
2. `Master` reacts to domain signals instead of guessing from lower-level slave
   observations

## Phase 4 - Reconcile slave-local faults with runtime state

### Goal

Keep slave-local visibility without lying to callers about the session.

### Changes

1. Revisit `await_operational/1` and `state/0` semantics in light of the
   refined model
2. Ensure docs make the contract explicit:
   - `:operational` means healthy cyclic runtime
   - `slaves/0` may still show local per-slave faults
3. Optionally expose a compact public health summary if `slaves/0` alone is too
   indirect

### Exit Criteria

1. Public lifecycle semantics are easy to explain in one paragraph
2. There is no hidden mismatch between docs, tests, and runtime behavior

## Risks

### Main risk: over-correcting toward pessimism

If every slave event drives `:recovering`, the master becomes noisy and loses
the benefit of tracking healthy domains separately.

### Main risk: staying too optimistic

If `slave_down` remains purely local in cases where the cyclic contract is
already broken, `:operational` becomes misleading.

### Constraint

The fix should prefer explicit classification and smaller helper paths over
adding more ad hoc state flags.

## Out of Scope

This plan does not include:

- changing the public driver API
- redesigning `Slave` health polling itself
- bit-level process-image packing
- new DC synchronization features

Those can be addressed later if needed, but they should not be mixed into the
runtime fault-classification cleanup.
