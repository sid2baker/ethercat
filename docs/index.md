# Documentation Index

This repository treats `docs/` as the system of record for agent-facing
knowledge.

Use this file as the entry point. Keep it small, stable, and cross-linked.

## Start Here

- [AGENTS.md](/home/n0gg1n/Development/Work/opencode/ethercat/AGENTS.md)
  Agent entrypoint and task routing map.
- [ARCHITECTURE.md](/home/n0gg1n/Development/Work/opencode/ethercat/ARCHITECTURE.md)
  System map, boundaries, and subsystem responsibilities.
- [README.md](/home/n0gg1n/Development/Work/opencode/ethercat/README.md)
  User-facing startup, examples, and public API overview.
- [examples/README.md](/home/n0gg1n/Development/Work/opencode/ethercat/examples/README.md)
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

## Subsystem Briefings

- [lib/ethercat/master.md](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/master.md)
  Master scan, configure, activate, and DC startup flow.
- [lib/ethercat/slave.md](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/slave.md)
  Slave ESM lifecycle, driver contract, PREOP/SAFEOP behavior.
- [lib/ethercat/domain.md](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/domain.md)
  Domain cycle loop, ETS image layout, and LRW hot path.

## Mechanical Checks

- `mix test`
  Validate behavior.

## Rules

1. New architectural decisions belong in `docs/design-docs/`.
2. Multi-step work belongs in `docs/exec-plans/`.
3. When behavior changes, update both the code and the corresponding doc.
4. Keep `AGENTS.md` as a map, not a dump.
