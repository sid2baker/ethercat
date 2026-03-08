# Harness Engineering

This repository is now managed as an agent-first codebase.

That does not mean “let the model improvise.” It means the repository itself is
responsible for making the right next step discoverable, verifiable, and cheap
to execute.

## Goals

1. Keep human attention focused on intent, acceptance criteria, and review.
2. Keep the repository legible enough that an agent can navigate it without
   tribal knowledge.
3. Encode recurring engineering judgment mechanically where possible.

## What This Means Here

### `AGENTS.md` is a map

`AGENTS.md` should stay short. Its job is to route an agent to:

- the architecture map
- the subsystem briefings
- the active execution plans
- the quality and debt trackers
- the external EtherCAT references

It should not try to duplicate the contents of those documents.

### `docs/` is the system of record

Repository-local, versioned artifacts are the only knowledge an agent can
reliably reason about during a task. That means:

- architectural decisions live in `docs/design-docs/`
- multi-step work lives in `docs/exec-plans/`
- external protocol knowledge lives in `docs/references/`
- current quality and debt live in `docs/QUALITY_SCORE.md` and
  `docs/exec-plans/tech-debt-tracker.md`

### Plans are first-class artifacts

For non-trivial work, the plan should exist in the repository before or during
implementation. That keeps the design, rollout order, and accepted tradeoffs
available to later agent runs.

### Harnesses matter as much as code

For this project, the main harnesses are:

- focused ExUnit coverage
- maintained hardware scripts
- loopback and latency benchmarks
- telemetry surfaces that expose runtime state clearly

The library is not “done” when a feature compiles. It is done when the harness
can prove the behavior.

## Mechanical Enforcement

Keep the documentation spine simple enough that normal refactor work can keep it
current:

1. required entry docs should exist
2. index files should stay accurate
3. the human-authored section of `AGENTS.md` should remain a map, not a dump

The goal is structure, not a second CI system inside markdown.

## Practical Standard

When a change lands:

1. update the code
2. update the subsystem briefing if behavior changed
3. update the design doc or execution plan if the architectural story changed
4. keep the repo runnable and testable by the existing harness

That is the standard for “aligned to harness engineering” in this codebase.
