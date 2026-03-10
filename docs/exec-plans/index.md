# Execution Plans Index

Execution plans are first-class repo artifacts. They track intent, progress,
and decision logs for multi-step work.

## Active

- [docs/exec-plans/active/master-domain-fault-classification.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/active/master-domain-fault-classification.md)
  Clarify which slave faults stay local, which faults make the cyclic runtime
  unhealthy, and simplify the surrounding `Master` / `Domain` code while that
  model is tightened.

## Completed

- [docs/exec-plans/completed/bus-scheduler-refactor.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/bus-scheduler-refactor.md)
  Centralized bus scheduling and batching policy.
- [docs/exec-plans/completed/coe-sdo-segmentation.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/coe-sdo-segmentation.md)
  Segmented CoE SDO upload and download support.
- [docs/exec-plans/completed/dc-sync1-latch-complete.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/dc-sync1-latch-complete.md)
  Historical narrow DC SYNC1/latch plan superseded by the broader DC alignment plan.
- [docs/exec-plans/completed/distributed-clocks-spec-alignment.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/distributed-clocks-spec-alignment.md)
  Distributed Clocks runtime/API alignment plan for the current library line.
- [docs/exec-plans/completed/link-transaction-api.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/link-transaction-api.md)
  Bus transaction API cleanup and link-boundary refactor.
- [docs/exec-plans/completed/refactor-roadmap.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/refactor-roadmap.md)
  Umbrella ordering document that landed the current spec-aligned runtime shape
  and moved the remaining gaps into focused debt.
- [docs/exec-plans/completed/runtime-module-decomposition.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/runtime-module-decomposition.md)
  Structural decomposition of the oversized `Master`, `Slave`, and `Domain`
  runtime modules into clearer subsystem collaborators.
- [docs/exec-plans/completed/simulator-generalization.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/simulator-generalization.md)
  Generalized `EtherCAT.Simulator*` into a reusable simulated-slave platform
  with typed objects/process data, reusable profiles, segmented CoE, widget
  APIs, and DC-aware deep coverage.
- [docs/exec-plans/completed/simulator-runtime-refactor.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/simulator-runtime-refactor.md)
  Decomposed `EtherCAT.Simulator` and `EtherCAT.Simulator.Slave.Runtime.Device` into
  explicit collaborators while preserving the public simulator API.
- [docs/exec-plans/completed/syncmanager-domain-spec-alignment.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/syncmanager-domain-spec-alignment.md)
  Process-data attachment-model refactor for split `{domain, SyncManager}` support.

## Ongoing Debt

- [docs/exec-plans/tech-debt-tracker.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/tech-debt-tracker.md)
  Cross-cutting gaps that are not worth promoting into a full active plan yet.

## Rules

1. Active plans describe work that still changes behavior.
2. Completed plans are historical context, not the live source of truth.
3. When a plan lands, move it to `completed/` and update this index in the same change.
