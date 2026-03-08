# Plan: SyncManager and Domain Spec Alignment

## Status

ACTIVE

## Goal

Remove the library-specific `one SyncManager -> one domain` rule and align the
process-data model with the EtherCAT spec summaries and the bundled reference
master material.

The target is:

1. one domain may map any SyncManager-backed process-data area it needs
2. multiple domains may map the same SyncManager-backed area
3. each `{domain, sync_manager}` attachment gets its own logical address and
   its own FMMU configuration
4. split output SyncManagers remain coherent across domains instead of
   clobbering each other

## Why This Refactor Exists

The current restriction is an implementation shortcut, not a spec rule.

Today the planner rejects multiple domain IDs for one SyncManager:

- `EtherCAT.Slave.ProcessDataPlan.resolve_sm_domain_id/2`
- `{:sync_manager_spans_multiple_domains, sm_index}`

That rule leaks upward into:

- slave PREOP registration
- reconnect caching
- signal dispatch indexing
- output staging
- examples and docs

The bundled IgH references point to a different model:

1. multiple domains are expected so PDOs can run at different rates
2. each domain consumes one FMMU in each participating slave
3. if any PDO entry in a SyncManager is registered to a domain, the complete
   SyncManager-protected memory region is mapped for that domain
4. separate FMMUs are prepared per `{domain, sync_manager}`

Relevant references:

- `docs/references/ethercat-spec/11-syncmanagers.md`
- `docs/references/ethercat-spec/12-fieldbus-memory-management-units-fmmu.md`
- `docs/references/ethercat-spec/13-process-data-objects-pdo-mapping.md`
- `docs/references/ethercat-spec/18-the-configuration-sequence-init-to-pre-op.md`
- `docs/references/ethercat-spec/19-transitioning-to-cyclic-operation-pre-op-to-op.md`
- `docs/references/igh/documentation/ethercat_doc.tex`
- `docs/references/igh/master/slave_config.c`

## Current Mismatch

### Planner

Current `ProcessDataPlan` collapses each SyncManager into one `SmGroup` with a
single `domain_id`.

Implication:

- one SM cannot legally appear in two domains
- the refactor boundary starts in the planner, not in `Domain`

### Registration and reconnect

Current registration caching is effectively keyed by `{sm_key, domain_id}` data
stored per signal, but the planner only ever produces one domain per SM.

Implication:

- reconnect reuse works for one attachment per SM
- reconnect cannot express one cached logical offset per `{domain, sm_key}`

### Input dispatch

Current `signal_registrations_by_sm` is keyed by `sm_key` only.

Implication:

- `{:domain_input, domain_id, ...}` is already sent by `Domain`
- but the slave-side decode index ignores `domain_id`
- two domains watching the same SM cannot be kept distinct

### Output staging

Current `write_output` reads and writes exactly one domain image for the signal.

Implication:

- if one output SM is split across multiple domains, one domain can overwrite
  the other domain's bits on the next cycle
- this is the highest-risk part of the refactor

## Target Model

Separate the three concepts that are currently fused:

### 1. SM Area

One physical SyncManager-backed process-data area in a slave:

- key: `{slave_name, {:sm, sm_index}}`
- fields: direction, physical start, control byte, total size

### 2. Domain Attachment

One domain's mapping of that SM area:

- key: `{domain_id, sm_key}`
- fields: logical address, FMMU index, signal subset for that domain

This is the object that should drive:

- `Domain.register_pdo/4`
- reconnect caching
- FMMU programming
- domain-local signal notifications

### 3. Canonical Output SM Image

For output SyncManagers only, keep one canonical full-SM image in the slave and
fan the merged bytes into every attached domain image.

This is required so:

- two domains writing different signals in the same output SM do not race
- faster domains do not revert bits owned by slower domains
- every LRW frame for that SM carries the same coherent full buffer

## Execution Order

## Phase 1 - Refactor the planner model

### Goal

Replace `one SmGroup per SM` with a model that can represent multiple domains
for one SM.

### Changes

1. introduce a planner result shaped around:
   - one SM-area description per `sm_index`
   - one attachment per `{sm_index, domain_id}`
2. remove `resolve_sm_domain_id/2`
3. keep the rule that each attachment covers the full SM byte range
4. preserve deterministic ordering for FMMU allocation and tests

### Acceptance

1. planner accepts requested signals from the same SM in multiple domains
2. planner still rejects invalid signal ranges and missing SII/SM data
3. planner output makes attachment boundaries explicit

## Phase 2 - Key runtime state by attachment, not bare SM

### Goal

Make registration, reconnect, and input decode attachment-aware.

### Changes

1. key cached logical offsets by `{domain_id, sm_key}`
2. key slave decode indexes by `{domain_id, sm_key}`
3. keep `Domain` notifications attachment-aware all the way to signal decode
4. update reconnect reuse to validate one cached offset per attachment

### Acceptance

1. one input SM can be present in multiple domains without decode collisions
2. reconnect reuse works when the same SM is registered into multiple domains
3. tests cover per-attachment cache hits and misses

## Phase 3 - Add coherent split-output support

### Goal

Support one output SyncManager in multiple domains without domain images
fighting each other.

### Changes

1. add a canonical per-SM output image in `EtherCAT.Slave`
2. change `write_output` to:
   - update the canonical image
   - fan the full merged SM bytes into every attached domain image
3. keep domain ETS rows as staging buffers for cycle assembly
4. ensure initial PREOP registration seeds every attached output domain with the
   same starting SM bytes

### Acceptance

1. two output signals in the same SM can live in different domains
2. writing one signal does not clear sibling bits owned by another domain
3. mixed-rate domains remain coherent across repeated writes

## Phase 4 - FMMU allocation and limits

### Goal

Match the reference-master model of one FMMU per `{domain, sync_manager}`.

### Changes

1. allocate FMMU indices per attachment, not per SM
2. surface a clear configuration error when the slave runs out of FMMUs
3. document the practical limit:
   - maximum domains per slave is bounded by available FMMUs

### Acceptance

1. split-SM multi-domain configs program separate FMMUs
2. FMMU exhaustion fails fast in PREOP with a targeted error

## Phase 5 - Update examples, docs, and hardware validation

### Goal

Replace the current example/documentation rule with the new behavior and prove
the refactor on real hardware.

### Changes

1. update `examples/multi_domain.exs`
2. update `examples/README.md`
3. update README language after the behavior lands
4. add a maintained hardware scenario that splits one SM across domains

Suggested validation scenarios:

1. input split:
   - EL1809 `:ch1` in domain `:fast`
   - EL1809 `:ch2` in domain `:slow`
2. output split:
   - EL2809 `:ch1` in domain `:fast`
   - EL2809 `:ch2` in domain `:slow`
3. reconnect:
   - disconnect and reconnect a slave whose SM is attached to multiple domains

### Acceptance

1. docs no longer claim one SM maps to exactly one domain
2. hardware examples show split-SM domains working
3. fault-tolerance paths still recover attachment caches correctly

## Risks and Decision Gates

### Highest risk: split outputs

Split-input support is mechanically straightforward.

Split-output support is not.

If Phase 3 is not complete, we should not partially expose multi-domain output
SM support. The safe fallback milestone is:

- allow multi-domain input SMs
- keep output SM splitting rejected with an explicit error

That is a valid intermediate checkpoint, but not the final target.

### WKC and domain semantics

Per-domain expected WKC must remain correct when the same slave participates in
multiple domains. This needs explicit tests, especially for:

- one slave with input-only split attachments
- one slave with output-only split attachments
- one slave participating bidirectionally across domains

### Recovery

The reconnect cache and degraded recovery logic must stay attachment-aware. The
refactor should not reintroduce the older `:not_open` or stale-registration
failure modes.

## Implementation Notes

Do not start in `Domain`.

Start in the planner and the slave-side registration model. `Domain` already
supports one ETS table per domain and can naturally hold the same `sm_key` in
different domain tables. The real mismatch is the planner/runtime assumption
that one SM has exactly one attachment.
