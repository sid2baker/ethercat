## Simulator Integration Loop

Use this folder as a bounded self-improvement loop for the simulator and the
master runtime.

The rule is simple:

1. Write a short scenario spec first as `NN_case_name.md`.
2. Add the smallest failing integration test as `NN_case_name_test.exs`.
3. Classify the failure:
   - simulator cannot express the fault
   - simulator expresses it, but assertions/observability are weak
   - master/domain/slave behavior is wrong
4. Fix the smallest layer that unblocks the scenario:
   - missing fault model -> extend simulator API
   - missing visibility -> extend snapshots, telemetry, or test helpers
   - product bug -> fix implementation
5. Re-run the targeted test, then the simulator suite.
6. Only then move to a harder scenario.

The point is to keep every improvement tied to a concrete scenario instead of
letting the loop invent arbitrary refactors.

## Naming

- Scenario doc: `NN_case_name.md`
- Matching test: `NN_case_name_test.exs`
- Shared harness code lives in `test/integration/support/`

## Current Scenario Set

- `00`: baseline healthy ring boot and PDO exchange
- `01`: transient full-response timeout
- `02`: cyclic WKC mismatch
- `03`: slave disconnect with health polling and reconnect
- `04`: raw frame corruption or stale/duplicate frame
- `05`: slave retreat to `SAFEOP` with health polling
- `06`: mailbox abort during startup or recovery
- `07`: combined fault script, e.g. timeout -> reconnect -> WKC skew
- `08`: delayed slave-local mutation after exchange-fault recovery
- `09`: milestone-aware slave-local fault after healthy polls
- `10`: segmented mailbox abort during upload/download
- `11`: reusable fault script with embedded milestone wait
- `12`: startup mailbox abort during driver PREOP mailbox configuration
- `13`: targeted logical-WKC skew without inventing a slave-local fault
- `14`: command-targeted WKC skew outside logical PDO traffic
- `15`: mailbox milestone-timed segmented abort after successful segment progress
- `16`: mailbox protocol-shape faults during public SDO upload
- `17`: malformed mailbox response headers during public SDO upload
- `18`: malformed CoE payloads during public SDO upload
- `19`: malformed segmented CoE upload responses
- `20`: malformed segmented CoE download acknowledgements
- `21`: startup segmented-download acknowledgement faults during PREOP configuration
- `22`: startup mailbox response timeouts during PREOP configuration
- `23`: public mailbox response timeouts during segmented SDO upload/download
- `24`: reconnect-time mailbox abort during PREOP rebuild without full-session restart
- `25`: reconnect-time mailbox response timeouts during PREOP rebuild without full-session restart
- `26`: reconnect-time malformed segmented-download acknowledgements during PREOP rebuild without full-session restart
- `27`: reconnect-time malformed final segmented-download acknowledgements during PREOP rebuild, including committed-write semantics
- `28`: reconnect-time PREOP fault script that fails once and self-heals on a later retry without manual fault clearing
- `29`: reconnect-time PREOP fault script that retains different mailbox failures on successive retries before eventual recovery
- `30`: reconnect-time PREOP mailbox degradation plus a later slave-local `SAFEOP` retreat during the same operational window
- `31`: reconnect-time PREOP mailbox degradation plus a later counted PDO-slave disconnect that forces a temporary master `:recovering` interval
- `32`: telemetry-triggered follow-up `SAFEOP` retreat armed on master recovery entry without an imperative mid-scenario injection
- `33`: PDO-participating slave disconnect whose reconnect-time PREOP mailbox failure must replace the stale critical disconnect fault so recovery can later finish cleanly
- `34`: retained reconnect PREOP mailbox failure that arms a later counted PDO disconnect through `Scenario.inject_fault_on_event/4` instead of an imperative mid-scenario action
- `35`: retained reconnect PREOP mailbox failure that arms a later counted PDO disconnect whose recovery entry then arms a follow-up `SAFEOP` retreat on another PDO slave
- `36`: captured `EL3202` reconnect-time PREOP timeout on a real startup SDO map that later arms a counted PDO disconnect while typed RTD decode must still recover cleanly

These are the current regression scenarios, not just backlog items. Each one
should keep its `.md` note and matching `_test.exs` file aligned.

## Current Fault Shapes

For datagram/runtime faults, prefer the builder surface on
`EtherCAT.Simulator.Fault`:

- `EtherCAT.Simulator.inject_fault(Fault.next(fault))`
- `EtherCAT.Simulator.inject_fault(Fault.next(fault, count))`
- `EtherCAT.Simulator.inject_fault(Fault.script([step, ...]))`
- `EtherCAT.Simulator.inject_fault(Fault.after_ms(fault, delay_ms))`
- `EtherCAT.Simulator.inject_fault(Fault.after_milestone(fault, milestone))`
- nested scheduling such as
  `Fault.disconnect(:outputs) |> Fault.next(30) |> Fault.after_ms(250) |> Fault.after_milestone(milestone)`

Current exchange-scoped faults:

- `:drop_responses`
- `{:wkc_offset, delta}`
- `{:command_wkc_offset, command_name, delta}`
- `{:logical_wkc_offset, slave_name, delta}`
- `{:disconnect, slave_name}`

Current milestones:

- `{:healthy_exchanges, count}`
- `{:healthy_polls, slave_name, count}`
- `{:mailbox_step, slave_name, step, count}`

Current in-script wait steps:

- `Fault.wait_for(Fault.healthy_exchanges(count))`
- `Fault.wait_for(Fault.healthy_polls(slave_name, count))`
- `Fault.wait_for(Fault.mailbox_step(slave_name, step, count))`

For raw transport corruption, use the UDP-edge API instead:

- `EtherCAT.Simulator.Udp.inject_fault(UdpFault.truncate())`
- `EtherCAT.Simulator.Udp.inject_fault(UdpFault.wrong_idx() |> UdpFault.next(count))`
- `EtherCAT.Simulator.Udp.inject_fault(UdpFault.script([UdpFault.unsupported_type(), ...]))`

Current UDP corruption modes:

- `:truncate`
- `:unsupported_type`
- `:wrong_idx`
- `:replay_previous`

For tooling and scenario output, prefer `Fault.describe/1` and
`UdpFault.describe/1` instead of rebuilding labels from tuple shapes.

`EtherCAT.Simulator.info/0` and `EtherCAT.Simulator.Udp.info/0` expose
queued and delayed fault state through `next_fault`, `pending_faults`,
`scheduled_faults`, and active `command_wkc_offsets` / `logical_wkc_offsets`,
including milestone `waiting_on` / `remaining`, so new scenarios should assert queue drain explicitly
instead of relying on sleeps alone.

Current mailbox protocol fault kinds:

- `:drop_response`
- `:counter_mismatch`
- `:toggle_mismatch`
- `{:mailbox_type, type}`
- `{:coe_service, service}`
- `:invalid_coe_payload`
- `{:sdo_command, command}`
- `:invalid_segment_padding`
- `{:segment_command, command}`

Direct mailbox fault injections remain sticky until `Simulator.clear_faults/0`.
The same mailbox protocol fault used as a step inside `Fault.script/1` is
consumed on first match, which is the preferred way to model "first retry
fails, later retry self-heals" reconnect scenarios.

## Cyclic Scenario Rules

Many simulator regressions are really cycle-level bugs, not generic timing
bugs. Write those scenarios in terms of exchanges, polls, and recovery windows
instead of wall-clock sleeps.

Use exchange-scoped timing when the master should observe a fault on the next
few cyclic turns:

- `Fault.next(fault)` / `Fault.next(fault, count)` for exact exchange windows
- `Fault.wait_for(Fault.healthy_exchanges(count))` when the test should resume
  after a known number of clean round trips
- `{:wkc_offset, delta}` or `{:logical_wkc_offset, slave, delta}` when the
  bug is about cyclic validity, not about a slave-local AL transition

Use poll- or mailbox-scoped timing when the interesting edge is slower than one
domain cycle:

- `Fault.wait_for(Fault.healthy_polls(slave_name, count))` for health-poll and
  reconnect stories
- `Fault.wait_for(Fault.mailbox_step(slave_name, step, count))` for segmented
  mailbox progress

Use wall-clock timing only when the trigger really is elapsed time:

- `Fault.after_ms/2` delays when a fault becomes active
- it does **not** simulate late-but-valid transport replies or random jitter
- if a scenario needs "reply arrives too late" semantics, that is a missing
  UDP-edge fault shape, not a reason to sprinkle `Process.sleep/1` into the
  test

For cyclic assertions, prefer checking the user-visible runtime effect instead
of inferring it from helper internals:

- domain invalid/recovered transitions
- master `:recovering` entry and exit
- retained or cleared slave faults
- simulator queue drain through `Expect.simulator_queue_empty/0`

That keeps cycle-level scenarios honest: the simulator schedules deterministic
fault windows, while the test asserts what the real master actually did with
those windows.

## Integration Helper API

Prefer the new test helpers for new scenarios:

- `EtherCAT.Integration.Expect`
  - standalone assertion helpers for plain ExUnit tests
  - `Expect.eventually/2`
  - `Expect.master_state/1`
  - `Expect.domain/2`
  - `Expect.slave/2`
  - `Expect.slave_fault/2`
  - `Expect.signal/3`
  - `Expect.trace_event/3`
  - `Expect.trace_note/3`
  - `Expect.simulator_queue_empty/0`
- `EtherCAT.Integration.Trace`
  - telemetry-backed timeline capture for failure diagnostics
  - uses `EtherCAT.Telemetry.events/0`, including master state transitions
  - prefer this over bespoke `:telemetry.attach` code in scenario tests
- `EtherCAT.Integration.Scenario`
  - optional multi-phase runner for longer recovery cases
  - keep `ctx` for scenario-owned assigns only; prefer `Expect` for live queries
  - `Scenario.inject_fault_on_event/4` arms telemetry-triggered follow-up faults
    without pushing master-observed milestones into simulator core
  - telemetry-triggered injections complete before the matching callback returns,
    so follow-up assertions do not depend on spawned-process races

## Next Directions

The next useful scenario after the captured-device `EL3202` reconnect PREOP mix case is:

- a split-domain captured-device variant that keeps the real hardware ring
  shape (`EK1100` / `EL1809` / `EL2809` / `EL3202`) but forces the RTD
  terminal through reconnect PREOP recovery while the digital loopback domain
  stays independently healthy

## When To Combine Scenarios

Keep the default shape as one scenario per regression.

Combine two fault stories only when all of these are true:

- they are one causal chain in the same operational window
- the second fault is only interesting because the first fault already
  happened
- the expected assertion is about the combined recovery behavior, not just the
  individual faults in sequence

Do **not** combine scenarios just because the setup ring is the same. Shared
builders and helpers are cheaper than mixed assertions and harder-to-read trace
output.

Good reasons to combine:

- retained reconnect PREOP degradation that later changes how a cyclic
  disconnect should be recovered
- master `:recovering` entry that should synchronously arm a follow-up runtime
  fault in the same scenario

Bad reasons to combine:

- "these are both mailbox faults"
- "these both mention SAFEOP"
- "this saves one more scenario file"

If a combined story stops being easy to name in one sentence, it probably
should stay split.

## Promotion Path

When a new idea shows up, promote it through the smallest layer that keeps the
behavior honest:

1. Add a simulator scenario when the bug only appears with the real master,
   transport, and recovery loop interacting together.
2. Add a focused master/slave/domain unit test when the integration scenario
   already proved the bug and the core state transition should stay pinned more
   cheaply.
3. Add a hardware variant only when the value is physical validation,
   capture generation, or simulator-drift detection.

That keeps this folder centered on the hardest class of failures:

- real runtime interaction bugs
- deterministic fault/recovery choreography
- cases that are too expensive or too unsafe to induce repeatedly on a bench

## Scenario Authoring Checklist

Before adding a new simulator scenario, check these in order:

1. Is the ring shape the smallest one that can still reproduce the bug?
2. Is the fault on the right boundary?
   Use `EtherCAT.Simulator` for datagram/runtime behavior and
   `EtherCAT.Simulator.Udp` for raw reply corruption.
3. Is the trigger modeled deterministically?
   Prefer `next`, milestones, or telemetry-triggered helpers over sleeps.
4. Is the assertion about the public runtime behavior?
   Prefer master/domain/slave state, retained faults, signals, and queue drain
   over helper-local implementation details.
5. If the scenario proves a product bug, did the fix also get a focused unit
   regression where that is cheaper to maintain?

For failure diagnostics, keep these by default:

- a short `.md` note that names the fault story in one sentence
- `Trace` capture for timeline context
- `Expect.simulator_queue_empty/0` when the scenario arms queued or scheduled
  faults

If a scenario still needs bespoke sleeps after that checklist, the API is
probably missing a better trigger or observation point.

## Common Anti-Patterns

Avoid these when extending the simulator suite:

- waiting with `Process.sleep/1` for a state change that already has a better
  trigger, milestone, or `Expect.eventually/2` assertion
- asserting exact trace lengths when the behavior under test is really a state
  transition or retained-fault outcome
- combining unrelated transport, mailbox, and slave-local faults into one test
  just because the ring setup is expensive
- reaching into simulator internals when the same behavior is visible through
  public master/domain/slave info or the signal API
- using a captured real-device fixture for a pure protocol-shape matrix where a
  smaller synthetic mailbox fixture would isolate the failure better
- using a synthetic fixture to claim realistic device-semantic coverage

When one of those feels tempting, it usually means one of three things:

- the simulator needs a narrower fault shape
- the helper layer needs a clearer assertion surface
- the scenario should be split into two regressions instead of forced into one

## Current Rule Of Thumb

- If the scenario is awkward because fault timing is too coarse, prefer a more
  scriptable simulator API over brittle sleeps in tests.
- If the scenario is easy to trigger but hard to assert, improve snapshots or
  test helpers before changing runtime behavior.
- If the scenario exposes a mismatch with expected master behavior, fix the bug
  before adding more scenarios on top.
- If the idea is really an address-space or protocol-limit boundary, cover it
  in focused master/startup unit tests instead of inventing giant simulator
  rings the transport cannot honestly address.
- Keep the fault boundary honest:
  datagram/runtime faults belong on `EtherCAT.Simulator`, while raw reply
  corruption belongs on `EtherCAT.Simulator.Udp`.
