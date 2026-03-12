# Documentation Index

Use this file as the entry point for repository documentation. Keep it small,
stable, and cross-linked.

Implementation truth lives first in source, tests, and module docs. `docs/`
adds design history, execution plans, and external references around that code.

## Start Here

- [AGENTS.md](/home/n0gg1n/Development/Work/opencode/ethercat/AGENTS.md)
  Agent entrypoint and task routing map.
- [ARCHITECTURE.md](/home/n0gg1n/Development/Work/opencode/ethercat/ARCHITECTURE.md)
  System map, boundaries, and subsystem responsibilities.
- [README.md](/home/n0gg1n/Development/Work/opencode/ethercat/README.md)
  User-facing startup, examples, and public API overview.
- [test/integration/hardware/README.md](/home/n0gg1n/Development/Work/opencode/ethercat/test/integration/hardware/README.md)
  Maintained hardware scripts and validation entry points.

## System Of Record

- [docs/design-docs/index.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/design-docs/index.md)
  Design history, deep dives, and architecture rationale.
- [docs/exec-plans/index.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/exec-plans/index.md)
  Active work, completed execution plans, and deferred debt.
- [docs/QUALITY_SCORE.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/QUALITY_SCORE.md)
  Current subsystem quality grades and the main gaps to close.
- [docs/references/README.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/references/README.md)
  External references: EtherCAT spec, IgH, SOEM, ESC register docs.

## Subsystem Module Docs

- [lib/ethercat.ex](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat.ex)
  Top-level API surface and session model.
- [lib/ethercat/master.ex](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/master.ex)
  Master scan, configure, activate, recover, and public status flow.
- [lib/ethercat/slave.ex](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/slave.ex)
  Slave ESM state-machine module, driver contract, and transition ownership.
- [lib/ethercat/domain.ex](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/domain.ex)
  Domain cycle loop ownership, ETS image contract, and LRW coordination.
- [lib/ethercat/bus.ex](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/bus.ex)
  Bus scheduler, transaction classes, and transport boundary.
- [lib/ethercat/dc.ex](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/dc.ex)
  Distributed Clocks maintenance runtime and lock/runtime reporting.

## Mechanical Checks

- `mix test`
  Validate behavior.

## Rules

1. New architectural decisions belong in `docs/design-docs/`.
2. Multi-step work belongs in `docs/exec-plans/`.
3. When behavior changes, update both the code and the corresponding doc.
4. Keep `AGENTS.md` as a map, not a dump.
