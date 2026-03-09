# Execution Plans Index

Execution plans are first-class repo artifacts. They track intent, progress,
and decision logs for multi-step work.

## Active

- [docs/exec-plans/active/refactor-roadmap.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/active/refactor-roadmap.md)
  Umbrella ordering document for the remaining architecture and spec-alignment refactors.
- [docs/exec-plans/active/runtime-module-decomposition.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/active/runtime-module-decomposition.md)
  Detailed plan for splitting the oversized `Master`, `Slave`, and `Domain`
  runtime modules into clearer subsystem collaborators.

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
- [docs/exec-plans/completed/syncmanager-domain-spec-alignment.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/completed/syncmanager-domain-spec-alignment.md)
  Process-data attachment-model refactor for split `{domain, SyncManager}` support.

## Ongoing Debt

- [docs/exec-plans/tech-debt-tracker.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/tech-debt-tracker.md)
  Cross-cutting gaps that are not worth promoting into a full active plan yet.

## Rules

1. Active plans describe work that still changes behavior.
2. Completed plans are historical context, not the live source of truth.
3. When a plan lands, move it to `completed/` and update this index in the same change.
