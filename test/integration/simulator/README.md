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
   - the master public API is making the fault awkward to express, observe, or recover from
   - the test/helper API is making the scenario awkward to write or assert
4. Say explicitly whether a better API should exist:
   - no API change needed
   - better master API would help
   - better simulator or test-helper API would help
5. If the scenario exposed a real fault, describe it concretely:
   - expected behavior
   - actual behavior
   - visible runtime impact
   - suspected broken layer and why
6. Write a short fix plan before editing code:
   - keep the failing test as the reproducer
   - patch the smallest honest layer
   - add or tighten cheaper unit coverage when it pins the same bug cleanly
   - rerun the targeted test and the relevant broader suite
7. Fix the smallest layer that unblocks the scenario:
   - missing fault model -> extend simulator API
   - missing visibility -> extend snapshots, telemetry, or test helpers
   - product bug -> fix implementation
   - awkward master API -> improve the public runtime surface if that is the real blocker
   - awkward test API -> improve helpers or fault builders if that is the real blocker
8. Re-run the targeted test, then the simulator suite.
9. Commit the fix with the scenario test path in the commit message body so history
   points back to the regression that found it.
10. Only then move to a harder scenario.

The point is to keep every improvement tied to a concrete scenario instead of
letting the loop invent arbitrary refactors.

## Naming

- Scenario doc: `NN_case_name.md`
- Matching test: `NN_case_name_test.exs`
- Shared harness code lives in `test/integration/support/`

## Required Outputs Per Scenario

Every worthwhile simulator scenario should leave behind these artifacts:

- a short scenario note and matching test
- an explicit API note:
  - `no API change needed`
  - `better master API suggested`
  - `better test/helper API suggested`
- when a fault is found, a concrete fault description:
  - what broke
  - what should have happened
  - what actually happened
  - how the failure stayed visible in master/domain/slave behavior
- a short repair plan
- the fix itself, unless the repo is genuinely blocked
- a commit that mentions the triggering test path, for example
  `test/integration/simulator/NN_case_name_test.exs`

Do not stop at "bug found". The expected loop is reproduce -> describe ->
plan -> fix -> verify -> commit.

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
- `37`: split-domain captured `EL3202` reconnect-time PREOP timeout where the digital loopback domain must stay healthy while the RTD retry path heals independently
- `38`: redundant passthrough-only reply (wkc=0, data unchanged) is discarded by the echo filter when the processed cross-delivery is delayed beyond the frame timeout
- `39`: redundant primary veth restore must not invalidate domain cycles or trigger master recovery after degraded single-port operation
- `40`: redundant bus accepts a degraded processed reply when the redundant copy from the opposite direction is delayed beyond the merge window
- `41`: multi-datagram BWR transactions in redundant mode must return wkc > 0 despite AF_PACKET outgoing echo race
- `42`: redundant primary port reconnection causes transient frame loss when slave PHY link-up timing differs from master NIC auto-negotiation (hardware-only, no simulator test)
- `43`: permanent PDO-slave disconnect should drive `:down` via health polling, allow reconnect healing, and force rediscovery if the returning slave lost its fixed station address

These are the current regression scenarios, not just backlog items. Each one
should keep its `.md` note and matching `_test.exs` file aligned.

The folder also contains a few transport-resilience checks that are not part of
the numbered scenario ladder. For example,
`raw_socket_noise_resilience_test.exs` is a focused raw-wire validation that
rogue EtherCAT frames do not break startup, not a scenario note with a
simulator repair loop.

## Transport Baseline Coverage

The baseline healthy-ring coverage is transport-aware.

- `test/integration/simulator/00_healthy_ring_transport_matrix_test.exs`
  always runs the UDP-backed happy path.
- The same scenario also includes raw-socket variants tagged `:raw_socket`.
  Those run when the raw veth pair is available.
- The same scenario includes redundant raw variants tagged
  `:raw_socket_redundant`. Those run when both redundant raw veth pairs are
  available.

For helper-driven scenarios built on `EtherCAT.IntegrationSupport.SimulatorRing`,
the default transport comes from `ETHERCAT_INTEGRATION_TRANSPORT`:

- unset or `udp` -> UDP transport
- `raw` -> single-link raw transport

Use an explicit `transport:` option in the test when the transport is part of
the regression story. Leave it implicit when the scenario is transport-agnostic
and should follow the suite default.

Redundant raw scenarios do not use that environment switch. Build those on
`EtherCAT.IntegrationSupport.RedundantSimulatorRing`, which always starts the
explicit dual-interface raw topology and exposes helpers such as
`disconnect_primary!/0`, `reconnect_primary!/0`, `set_break_after!/1`, and
`heal!/0` for ring-specific transport stories.

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

Current datagram/runtime fault effects:

- `:drop_responses`
- `{:wkc_offset, delta}`
- `{:command_wkc_offset, command_name, delta}`
- `{:logical_wkc_offset, slave_name, delta}`
- `{:disconnect, slave_name}`
- `{:retreat_to_safeop, slave_name}`
- `{:power_cycle, slave_name}`
- `{:latch_al_error, slave_name, code}`

These can be built through `EtherCAT.Simulator.Fault`, for example:

- `Fault.drop_responses()`
- `Fault.wkc_offset(delta)`
- `Fault.command_wkc_offset(:lrw, delta)`
- `Fault.logical_wkc_offset(:outputs, delta)`
- `Fault.disconnect(:outputs)`
- `Fault.retreat_to_safeop(:inputs)`
- `Fault.power_cycle(:outputs)`
- `Fault.latch_al_error(:inputs, code)`

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

Current mailbox stages accepted by `Fault.mailbox_abort/5` and
`Fault.mailbox_protocol_fault/5`:

- `:request`
- `:upload_init`
- `:upload_segment`
- `:download_init`
- `:download_segment`

Use the mailbox-specific builders when the scenario is about CoE/mailbox
protocol semantics rather than generic datagram loss:

- `Fault.mailbox_abort(slave_name, index, subindex, abort_code, opts)`
- `Fault.mailbox_protocol_fault(slave_name, index, subindex, stage, fault_kind)`

Direct mailbox and slave-local fault injections remain sticky until
`Simulator.clear_faults/0`. The same mailbox protocol fault used as a step
inside `Fault.script/1` is consumed on first match, which is the preferred way
to model "first retry fails, later retry self-heals" reconnect scenarios.

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
  - `Expect.stays/2`
  - `Expect.master_state/1`
  - `Expect.domain/2`
  - `Expect.slave/2`
  - `Expect.slave_fault/2`
  - `Expect.signal/3`
  - `Expect.trace_event/3`
  - `Expect.trace_note/3`
  - `Expect.trace_sequence/2`
  - `Expect.simulator_queue_empty/0`
    this checks the simulator-core fault queue and active UDP pending faults
    when the UDP endpoint is running
- `EtherCAT.Integration.Trace`
  - telemetry-backed timeline capture for failure diagnostics
  - uses `EtherCAT.Telemetry.events/0`, including master state transitions
  - prefer this over bespoke `:telemetry.attach` code in scenario tests
- `EtherCAT.IntegrationSupport.SimulatorRing`
  - boots the maintained UDP or single-link raw ring around the shared driver fixtures
  - honors `ETHERCAT_INTEGRATION_TRANSPORT` unless the test passes an explicit
    `transport:` override
- `EtherCAT.IntegrationSupport.RedundantSimulatorRing`
  - boots the maintained redundant raw ring on the dual-interface topology
  - use this when the regression is about redundant-path behavior, primary-link
    toggling, or deterministic ring-break choreography
- `EtherCAT.Integration.Scenario`
  - optional multi-phase runner for longer recovery cases
  - `Scenario.trace/1` enables timeline capture for the whole scenario
  - keep `ctx` for scenario-owned assigns only; prefer `Expect` for live queries
  - `Scenario.inject_fault_on_event/4` arms telemetry-triggered follow-up faults
    without pushing master-observed milestones into simulator core
  - `Scenario.inject_fault/2`, `Scenario.clear_faults/1`, and
    `Scenario.capture/3` keep longer scenarios readable without bespoke setup
    processes
  - telemetry-triggered injections complete before the matching callback returns,
    so follow-up assertions do not depend on spawned-process races

## API Pressure Is Signal

When a scenario is awkward, say why.

The loop should explicitly call out when a better API would improve the work:

- master API pressure:
  - the public `EtherCAT` surface makes it too hard to observe the fault honestly
  - recovery state is visible internally but awkward to assert publicly
  - callers need lower-level knowledge than they should to reproduce or verify behavior
- test API pressure:
  - fault builders are too coarse for a deterministic scenario
  - assertions require too much boilerplate or helper-local knowledge
  - the scenario needs sleeps because the helper surface lacks a real trigger or observation point

If a better API seems warranted, say so explicitly even if the current change
does not implement it. Also say whether that API change is:

- required to land the scenario honestly now
- useful follow-up work, but not required for the current fix

Prefer small, truthful API improvements over helper-local hacks or brittle
test code.

## Next Directions

The split-domain captured-device follow-up to scenario `36` is now covered by
scenario `37`, and the full disconnect/reconnect-healing story now has an
address-loss variant in scenario `43`.

Only add a new "next" placeholder here when there is a concrete captured fault
story to name. Until then, use the checklist below to decide whether the next
improvement belongs in a new simulator scenario, a cheaper unit regression, or
bench-only validation.

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

## Fault Report And Repair Loop

When a simulator scenario finds a product fault, the LLM should leave a clear
repair trail:

1. Name the fault in one sentence.
2. Describe the trigger and expected behavior.
3. Describe the actual behavior and the visible runtime damage.
4. State whether the problem is in:
   - master runtime behavior
   - slave behavior
   - domain behavior
   - simulator fault modeling
   - test/helper API
   - master public API
5. Write a short plan for the smallest honest fix.
6. Implement the fix instead of stopping at diagnosis.
7. Verify the triggering test first, then the relevant broader suite.

If the fault cannot be fixed in the current change, say exactly what blocks it.
Do not silently leave a reproduced fault without a plan.

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
5. Did the scenario expose master API pressure or test-helper API pressure?
   If yes, say so explicitly even if the improvement is deferred.
6. If the scenario proves a product bug, did the fix also get a focused unit
   regression where that is cheaper to maintain?

For failure diagnostics, keep these by default:

- a short `.md` note that names the fault story in one sentence
- `Trace` capture for timeline context
- `Expect.simulator_queue_empty/0` when the scenario arms queued or scheduled
  faults

If a scenario still needs bespoke sleeps after that checklist, the API is
probably missing a better trigger or observation point.

## Commit Expectations

If a scenario exposes a real bug or a required API improvement, commit the fix
after verification.

That commit should:

- mention the triggering scenario test path in the body, for example
  `Found by: test/integration/simulator/24_reconnect_preop_mailbox_abort_test.exs`
- summarize the fault in plain language
- summarize the fix and any API adjustments
- mention validation that was run

The commit should make it easy to answer:

- which test found this fault?
- what was broken?
- what changed to fix it?

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
- If the scenario exposes master API pressure, say so explicitly instead of
  normalizing awkward call patterns in the test.
- If the scenario exposes a mismatch with expected master behavior, fix the bug
  before adding more scenarios on top, and commit with the triggering test path.
- If the idea is really an address-space or protocol-limit boundary, cover it
  in focused master/startup unit tests instead of inventing giant simulator
  rings the transport cannot honestly address.
- Keep the fault boundary honest:
  datagram/runtime faults belong on `EtherCAT.Simulator`, while raw reply
  corruption belongs on `EtherCAT.Simulator.Udp`.
