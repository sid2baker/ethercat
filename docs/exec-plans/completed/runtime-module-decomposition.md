# Plan: Runtime Module Decomposition

## Status

COMPLETE

## Goal

Reduce the concentration of protocol complexity in:

- `lib/ethercat/master.ex`
- `lib/ethercat/slave.ex`
- `lib/ethercat/domain.ex`

without reducing protocol scope or reopening recently settled semantics.

The protocol behavior is real and should stay. The current file shape is not.
This plan aims to make the runtime easier to reason about, easier to test, and
safer to evolve while staying spec-first.

## Outcome

This decomposition is complete for the current library line.

Landed runtime shape:

- `EtherCAT.Master` delegates to `Master.Startup`, `Master.Activation`,
  `Master.Recovery`, `Master.Session`, and `Master.Status`
- `EtherCAT.Slave` delegates to `Slave.Runtime.Bootstrap`,
  `Slave.ProcessData`, `Slave.Mailbox`, `Slave.Runtime.DCSignals`,
  `Slave.Runtime.Transition`, `Slave.Runtime.Signals`,
  `Slave.Runtime.Outputs`, `Slave.Runtime.Status`,
  `Slave.Runtime.Calls`, and `Slave.Runtime.Configuration`
- `EtherCAT.Domain` delegates to `Domain.Cycle`, `Domain.Image`,
  `Domain.Calls`, and `Domain.Status`

The remaining work is no longer structural decomposition. Future changes should
start from these boundaries instead of reopening the old large-module shape.

## Current Problem

Current approximate size:

1. `master.ex` — ~2040 lines
2. `slave.ex` — ~2036 lines
3. `domain.ex` — ~610 lines

The complexity itself is mostly justified by EtherCAT:

- startup discovery and INIT reset
- ESM transitions and AL error handling
- SII parsing
- SyncManager/FMMU programming
- mailbox / CoE
- DC setup and latch handling
- runtime recovery

What is *not* justified is concentrating too much of that behavior inside single
`gen_statem` modules.

## Design Rules

1. Keep protocol semantics. This is a structural refactor, not a feature trim.
2. Keep `gen_statem` shells thin. State machines should route events and own
   runtime state, not inline every workflow.
3. Extract by protocol boundary, not by arbitrary utility function count.
4. Favor pure helper modules for plan/build/decision logic.
5. Side-effecting workflow modules may call `Bus`, `Domain`, `Slave`, or `DC`,
   but should remain scoped to one subsystem concern.
6. Do not add compatibility shims just to preserve old internal call shapes.

## Reference Alignment

This plan aligns to the feature grouping in:

- [docs/references/ethercat-spec/01-llm-reference-index.md](/home/n0gg1n/Development/Work/opencode/ethercat/docs/references/ethercat-spec/01-llm-reference-index.md)

The spec/reference notes do not prescribe Elixir module boundaries. They do
define the protocol areas that should remain visible after extraction.

| Proposed runtime area | Reference chapters |
|---|---|
| `Master.Startup` | discovery and initialization flow: chapters 17, 18 |
| `Master.Activation` | cyclic activation flow: chapter 19 |
| `Master.Recovery` | continuous loop, WKC, and runtime fault discipline: chapters 04, 20 |
| `Slave.Transition` | ESM and AL control/status: chapters 05, 06, 07 |
| `Slave.Bootstrap` | ESC identity and SII reads: chapters 08, 09, 10 |
| `Slave.ProcessData` | SyncManagers, FMMUs, PDO mapping: chapters 11, 12, 13 |
| `Slave.DCSignals` | DC principles, delay, and registers: chapters 14, 15, 16 |
| `Slave.Mailbox` | remaining mailbox / application-layer work: chapter 21 |
| `Domain.Cycle` | continuous cyclic LRW loop and WKC validity: chapters 04, 20 |
| `Domain.Image` / `Domain.Status` | implementation-facing helpers; no direct protocol object, but they must preserve the semantics above |

The decomposition is considered aligned if:

1. extracted modules keep the same protocol ownership implied by the chapter map
2. implementation helpers do not invent new protocol semantics
3. BEAM-side structure clarifies, rather than obscures, the EtherCAT flow

## Target Shape

### Master

Keep `EtherCAT.Master` as the runtime owner of:

- public API entrypoints
- `gen_statem` state transitions
- retained session/runtime state
- final policy decisions

Move workflow logic into collaborators such as:

- `EtherCAT.Master.Startup`
  - scan stability
  - INIT reset / station assignment
  - topology reads
  - initial child start sequence
- `EtherCAT.Master.Activation`
  - DC runtime start
  - domain cycling start
  - slave OP activation
- `EtherCAT.Master.Recovery`
  - runtime fault classification
  - retry / restart decisions
  - degraded vs recovering transitions
- `EtherCAT.Master.Session`
  - process monitor bookkeeping
  - teardown / stop ordering
- `EtherCAT.Master.Status`
  - phase mapping
  - public query assembly
  - failure/reply summaries

### Slave

Keep `EtherCAT.Slave` as the runtime owner of:

- public API entrypoints
- `gen_statem` state transitions
- retained slave-local runtime state
- final state-transition sequencing

Move workflow logic into collaborators such as:

- `EtherCAT.Slave.Runtime.Bootstrap`
  - INIT to PREOP initialization
  - SII / ESC info reads
- `EtherCAT.Slave.ProcessData`
  with `EtherCAT.Slave.ProcessData.Plan` and `EtherCAT.Slave.ProcessData.Signal`
  - process-data plan application
  - domain registration
  - SyncManager / FMMU programming
  - output SM staging helpers
- `EtherCAT.Slave.Mailbox`
  - mailbox setup
  - CoE SDO upload/download
  - mailbox driver-step execution
- `EtherCAT.Slave.Runtime.DCSignals`
  - sync/latch planning
  - DC register programming
  - latch event polling/reads
- `EtherCAT.Slave.Runtime.Transition`
  - ESM transition walks
  - AL polling / ack-error flow
- `EtherCAT.Slave.Runtime.Signals`
  - subscription bookkeeping
  - input decode / dispatch helpers

### Domain

Keep `EtherCAT.Domain` as one runtime process module. It is already closer to a
single concern than `Master` or `Slave`.

Still extract the dense hot-path helpers into collaborators such as:

- `EtherCAT.Domain.Cycle`
  - frame build
  - LRW execution result classification
  - miss/invalid bookkeeping decisions
- `EtherCAT.Domain.Image`
  - ETS row shape
  - read/write/sample helpers
  - input slice updates
- `EtherCAT.Domain.Status`
  - stats/info assembly
  - telemetry payload shaping

The goal is not many tiny modules. The goal is to stop inlining the entire
cycle implementation into one file.

## Execution Order

## Phase 1 - Lock current behavior before moving code

### Status

COMPLETE

### Goal

Add or tighten focused tests around the current stateful behaviors before
extracting implementation modules.

### Changes

1. assert `Master` startup / recovery transitions more explicitly
2. assert `Slave` init/preop/op/down/reconnect behaviors more explicitly
3. assert `Domain` valid / invalid / stopped cycle bookkeeping more explicitly
4. assert public query surfaces stay stable while internals move

### Exit Criteria

1. targeted tests fail if extraction changes semantics
2. current runtime contracts are documented by tests, not just code reading

## Phase 2 - Extract Master workflows

### Goal

Reduce `EtherCAT.Master` to a stateful coordinator shell.

### Status

COMPLETE

### Changes

1. move startup/configuration helpers into `Master.Startup`
2. move activation helpers into `Master.Activation`
3. move recovery helpers into `Master.Recovery`
4. move teardown/process-monitor helpers into `Master.Session`
5. move summary/phase/query assembly into `Master.Status`

### Exit Criteria

1. `Master` state handlers are primarily event routing and policy selection
2. protocol workflows live outside the shell
3. no startup/recovery semantic regressions

## Phase 3 - Extract Slave workflows

### Goal

Reduce `EtherCAT.Slave` to a stateful slave-runtime shell.

### Status

COMPLETE

### Changes

1. move bootstrap and PREOP entry sequence into `Slave.Bootstrap`
2. move process-data registration / SM / FMMU logic into `Slave.ProcessData`
3. move mailbox/CoE logic into `Slave.Mailbox`
4. move DC/latch planning and execution into `Slave.DCSignals`
5. move ESM transition helpers into `Slave.Transition`
6. move subscription/input-decode helpers into `Slave.Signals`

### Exit Criteria

1. `Slave` state handlers no longer inline mailbox, DC, and process-data logic
2. extracted modules follow protocol boundaries rather than utility sprawl
3. reconnect / PREOP reconfigure behavior remains intact

## Phase 4 - Extract Domain hot-path helpers

### Goal

Keep `Domain` as a single runtime process but reduce the density of its cycle
implementation.

### Status

COMPLETE

### Changes

1. move image row read/write/sample helpers into `Domain.Image`
2. move cycle-result classification and miss handling into `Domain.Cycle`
3. move info/stats payload assembly into `Domain.Status`

### Exit Criteria

1. `Domain` still reads as one runtime concern
2. hot-path branches are decomposed into testable helpers
3. ETS row semantics and telemetry stay explicit

## Phase 5 - Reconcile docs and sizing goals

### Goal

Make the new runtime shape visible and keep the repo from drifting back toward
god modules.

### Status

COMPLETE

### Changes

1. update subsystem docs to point at the extracted collaborators
2. document the retained ownership split:
   - `Master` owns intent/session policy
   - `Slave`, `Domain`, and `DC` own live runtime state
3. add a simple structural rule of thumb in docs:
   - state-machine shell modules should mostly route and coordinate
   - protocol helpers should hold workflow details

### Exit Criteria

1. docs match the new module boundaries
2. future refactors have a clear architectural target to preserve

## Non-Goals

Do not bundle these into this plan:

1. protocol feature expansion
2. sub-millisecond scheduling work
3. motion-control / drive-profile layers
4. public API growth unrelated to the decomposition

## Success Metrics

1. `Master` and `Slave` are no longer ~2000-line mixed-concern modules
2. major workflows are discoverable by subsystem name
3. tests can target startup, recovery, mailbox, process-data, and DC behavior
   without entering giant files
4. the codebase stays spec-shaped while becoming structurally easier to change
