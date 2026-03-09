---
tracker:
  kind: linear
  # Find your project slug in the Linear URL:
  # linear.app/<workspace>/project/<project-name>-<id>
  # Copy the last segment, e.g. "ethercat-0c79b11b75ea"
  project_slug: "ethercat-b8d52f3ad4e8"
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done

polling:
  interval_ms: 5000

workspace:
  root: ~/code/ethercat-workspaces

hooks:
  after_create: |
    git clone --depth 1 git@github.com:sid2baker/ethercat.git .
    mix deps.get
    git clone --depth 1 https://gitlab.com/etherlab.org/ethercat.git docs/references/igh
    git clone --depth 1 https://github.com/OpenEtherCATsociety/SOEM.git docs/references/soem
  before_run: |
    git fetch origin main --depth 1
    git merge --ff-only origin/main 2>/dev/null || true
  before_remove: ""

agent:
  max_concurrent_agents: 3
  max_turns: 30

codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=high app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on a Linear ticket `{{ issue.identifier }}`: **{{ issue.title }}**

{% if retry_context %}
Previous attempt context:
{{ retry_context }}
{% endif %}

**Ticket state**: {{ issue.state }}
**URL**: {{ issue.url }}

{% if issue.description %}
**Description**:
{{ issue.description }}
{% endif %}

## Instructions

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth, permissions, or secrets that cannot be worked around).
3. Your final message must report only: completed actions and any blockers encountered.
4. Work only in the provided repository clone. Never push to remotes you did not clone from.
5. Read `AGENTS.md` before any code change — it contains hard rules for this codebase.

## Prerequisite: Linear Access

The `linear_graphql` tool is injected into your session. Use it for all Linear operations (state transitions, comments, workpad updates). Never shell out to Linear APIs directly.

## GitHub Connectivity Blocker Protocol (sandbox-specific)

This environment may block outbound DNS/TCP/socket access to GitHub.

If any publish step fails with network-resolution or socket errors (for example `Could not resolve hostname github.com`, `Could not resolve host`, `Temporary failure in name resolution`, or `Operation not permitted` while opening sockets):

1. Stop push/publish retries immediately after the first failure.
2. Add a concise blocker brief to the existing `## Codex Workpad` comment including:
   - exact command attempted,
   - exact error text,
   - timestamp,
   - statement that sandbox networking prevents remote publish from this run.
3. Move the issue to `Human Review` with the blocker noted in the workpad.
4. Do not continue implementation once this blocker is confirmed.

## Status Routing

Determine the ticket's current state and follow the matching flow:

| State | Action |
|-------|--------|
| `Backlog` | Do not modify the ticket. Exit. |
| `Todo` | Transition to `In Progress` immediately, then work the ticket. |
| `In Progress` | Resume from workpad state; continue implementation. |
| `Human Review` | Do not implement changes. Poll for feedback only. |
| `Merging` | Open and follow `.codex/skills/land/SKILL.md` exactly. |
| `Rework` | Reset: read latest PR feedback, create a fresh branch if needed, implement corrections. |

## Workpad

Maintain a single persistent comment on the issue with the header `## Codex Workpad`. Update it at the start of every session and after each significant step. Never create a second workpad comment — edit the existing one.

Workpad format:

```
## Codex Workpad
`<hostname>:<abs-path>@<short-sha>`

### Plan
- [ ] Step with sub-tasks

### Acceptance Criteria
- [ ] Criteria drawn from ticket description

### Validation
- mix compile --warnings-as-errors
- mix test

### Notes
- YYYY-MM-DD HH:MM — progress entry

### Confusions
(only include when execution was unclear)
```

## Before Transitioning to Human Review

All of the following must be true:
- [ ] All acceptance criteria from the workpad are met
- [ ] `mix compile --warnings-as-errors` passes with no warnings
- [ ] `mix test` passes
- [ ] A PR exists with a clear title and filled-out body (use `.github/pull_request_template.md`)
- [ ] All CI checks are green
- [ ] Workpad is fully up to date

## Implementation Rules (from AGENTS.md)

**API evolution (pre-release)**: Prefer API clarity over backward compatibility. If a better API requires a breaking change, make it and update call sites directly. Do not add compatibility shims or deprecation layers unless explicitly requested.

**Bitwise**: Never use `import Bitwise` or operators (`&&&`, `|||`, `band`, `bor`). Always use binary pattern matching to extract bit fields.

**gen_statem enter callbacks**: May not transition state. Enter callbacks are for side-effects only (arming timers, telemetry). State-deciding logic belongs in the event handler that calls `{:next_state, ...}`.

**Register writes**: Always use `Registers.*` functions from `lib/ethercat/slave/registers.ex`. Never hardcode register addresses.

**Orientation**: Read the relevant module docs/source file before editing any module:
- `lib/ethercat/slave.ex` before touching `slave.ex`
- `lib/ethercat/master.ex` before touching `master.ex`
- `lib/ethercat/domain.ex` before touching `domain.ex`
- `docs/exec-plans/tech-debt-tracker.md` to understand known gaps
- `docs/exec-plans/active/` to find existing plans before creating duplicate work

## Workflow

1. Read `AGENTS.md` and the relevant component module docs/source file.
2. Update workpad with plan and acceptance criteria.
3. Implement on a feature branch (`git checkout -b <issue-id>-<short-slug>`).
4. Verify with `mix compile --warnings-as-errors && mix test` after every non-trivial change.
5. When done, run the `push` skill (`.codex/skills/push/SKILL.md`) to create the PR.
6. If push fails due to GitHub DNS/socket/network restrictions, follow the `GitHub Connectivity Blocker Protocol (sandbox-specific)` and stop retries.
7. Transition ticket to `Human Review` after successful publish, or immediately after recording the confirmed connectivity blocker.
