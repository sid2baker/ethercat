# EtherCAT Hardening Arena

This README is written for an LLM that generates integration tests.

Your job is not to add more happy-path coverage. Your job is to try to break
the real EtherCAT master implementation with deterministic tests that expose
transport faults, WKC faults, AL-state regressions, reconnect bugs, mailbox
corruption, and misleading recovery behavior.

Treat the simulator as the default arena. Treat the hardware ring as the final
proof layer. The library is meant for industrial use, so robustness matters
more than demo breadth. A good test proves that the master fails visibly,
recovers correctly when it should, and never reports optimistic state while the
bus is actually degraded.

Despite living under `test/integration/hardware/`, this file defines the full
hardening workflow:

1. invent or capture a realistic failure story
2. reproduce it in the simulator with the smallest deterministic test
3. fix the smallest broken layer
4. promote the strongest cases to the real ring

## Read First

Implementation truth lives here:

- `ARCHITECTURE.md`
- `lib/ethercat.ex`
- `lib/ethercat/master.ex`
- `lib/ethercat/domain.ex`
- `lib/ethercat/slave.ex`
- `lib/ethercat/simulator.ex`
- `lib/ethercat/simulator.md`
- `test/integration/simulator/README.md`
- `test/integration/simulator/SCENARIO_TEMPLATE.md`
- `test/integration/support/simulator_ring.ex`
- `test/integration/support/expect.ex`
- `test/integration/support/scenario.ex`
- `test/integration/support/trace.ex`

Read existing simulator scenarios before adding a new one. They are the current
regression corpus, not speculative examples.

## Mission

Generate tests that answer this question:

> "How can this master be made to fail in a way that would matter on a real
> machine, and how do we prove the failure is handled honestly?"

A useful scenario usually maps to one of these real-world classes:

- transient full-bus timeout
- stale, duplicated, truncated, or malformed transport replies
- targeted logical or command WKC skew
- slave disconnect and reconnect
- slave retreat to `SAFEOP`
- latched AL error
- PREOP mailbox configuration failure during startup or recovery
- segmented mailbox upload/download corruption
- mixed causal chains where one failure changes the meaning of the next one

## Rules Of Engagement

- Start in `test/integration/simulator/`, not on physical hardware.
- Every scenario gets a pair:
  - `NN_case_name.md`
  - `NN_case_name_test.exs`
- One scenario should prove one regression story. Do not mix unrelated failures
  just because the setup ring is shared.
- Assert public behavior, not helper internals:
  - master state
  - domain health and invalid reason
  - slave fault visibility
  - recovery completion
  - simulator queue drain
- Prefer exchange counts, health polls, and mailbox milestones over
  `Process.sleep/1`.
- If the simulator cannot express the fault honestly, extend the simulator at
  the smallest valid boundary instead of weakening the test.
- Do not hide faults. A transport, WKC, AL-state, or topology problem must stay
  visible in runtime state or telemetry.
- Keep hardware as a promotion gate, not as the first place you discover the
  scenario.

## Scoreboard

Use this as a lightweight game. Higher score means higher hardening value.

| Score | Scenario quality |
|------:|------------------|
| 1 | Single deterministic fault with clear invalid/recovered assertions |
| 2 | Fault proves retained visibility across recovery or reconnect |
| 3 | Causal chain where the second failure only matters because the first happened |
| 4 | Captured-device or ring-shaped scenario using `ring: :hardware` or a custom simulated ring |
| 5 | Scenario exposes a product bug, missing observability, or a simulator gap that had to be fixed |

Penalty rules:

- `-1` if the scenario relies on wall-clock sleeps when milestones exist
- `-1` if assertions only check "it comes back eventually" without checking the
  degraded interval
- `-2` if the test combines unrelated faults into unreadable noise

Boss fights are allowed only when the failures are one causal chain in one
operational window.

## Default Workflow

1. Pick one industrially relevant failure story.
2. Write `NN_case_name.md` using `test/integration/simulator/SCENARIO_TEMPLATE.md`.
3. Add the smallest failing integration test as `NN_case_name_test.exs`.
4. Use existing helpers first:
   - `EtherCAT.IntegrationSupport.SimulatorRing`
   - `EtherCAT.Integration.Expect`
   - `EtherCAT.Integration.Scenario`
   - `EtherCAT.Integration.Trace`
5. Classify the failure:
   - simulator API gap
   - observability gap
   - product bug
6. Fix only the smallest layer that makes the scenario honest.
7. Re-run the targeted scenario, then the simulator suite.
8. If the scenario represents a real bench risk, promote it to a hardware run.

## Attack Catalog

Use the existing simulator fault builders before inventing anything new.

### Runtime fault surface

`EtherCAT.Simulator.Fault` already supports:

- `Fault.drop_responses()`
- `Fault.wkc_offset(delta)`
- `Fault.command_wkc_offset(command, delta)`
- `Fault.logical_wkc_offset(slave, delta)`
- `Fault.disconnect(slave)`
- `Fault.retreat_to_safeop(slave)`
- `Fault.latch_al_error(slave, code)`
- `Fault.mailbox_abort(slave, index, subindex, abort_code, opts \\ [])`
- `Fault.mailbox_protocol_fault(slave, index, subindex, stage, kind)`
- `Fault.next(fault, count)`
- `Fault.after_ms(fault, delay_ms)`
- `Fault.after_milestone(fault, milestone)`
- `Fault.script([step, ...])`
- `Fault.wait_for(Fault.healthy_exchanges(count))`
- `Fault.wait_for(Fault.healthy_polls(slave, count))`
- `Fault.wait_for(Fault.mailbox_step(slave, step, count))`

### UDP-edge corruption surface

`EtherCAT.Simulator.Udp.Fault` already supports:

- `UdpFault.truncate()`
- `UdpFault.unsupported_type()`
- `UdpFault.wrong_idx()`
- `UdpFault.replay_previous()`
- counted windows with `UdpFault.next/2`
- ordered corruption scripts with `UdpFault.script/1`

### Ring builders

Use the existing simulated rings before building new ones:

- default loopback ring: `SimulatorRing.boot_operational!()`
- hardware-shaped ring with RTD terminal: `SimulatorRing.boot_operational!(ring: :hardware)`
- segmented mailbox ring: `SimulatorRing.boot_operational!(ring: :segmented)`

If the existing rings are too small, build the smallest custom device list that
proves the fault. Do not create a larger ring unless the larger topology is the
actual point of the regression.

## What A Good Test Looks Like

Use a shape like this:

```elixir
defmodule EtherCAT.Integration.Simulator.SomeFaultTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    SimulatorRing.boot_operational!()
    :ok
  end

  test "master enters recovery and returns only after the fault is gone" do
    assert :ok = Simulator.inject_fault(Fault.drop_responses() |> Fault.next(30))

    Expect.eventually(fn ->
      Expect.master_state(:recovering)
      Expect.domain(:main, last_invalid_reason: :timeout)
    end)

    Expect.eventually(fn ->
      Expect.master_state(:operational)
      Expect.domain(:main, cycle_health: :healthy)
      Expect.simulator_queue_empty()
    end)
  end
end
```

For longer recovery chains, prefer `EtherCAT.Integration.Scenario` plus trace
capture over bespoke sleeps or ad hoc telemetry code.

## Scenario Ideas Worth Pursuing

Prioritize gaps that would matter on a plant floor:

- repeated disconnect and reconnect waves on a PDO slave
- reconnect-time PREOP mailbox failure that replaces a stale runtime fault
- targeted logical WKC skew on one slave while the rest of the domain stays healthy
- command-targeted WKC skew outside PDO traffic
- malformed segmented download acknowledgements during reconnect PREOP rebuild
- SAFEOP retreat that happens only after a healthy recovery interval
- AL error latch followed by a separate cyclic fault to verify fault replacement
- stale or replayed UDP response that should never be accepted as healthy data
- split-domain or shared-SyncManager cases where one domain must stay honest
  while another is degraded
- hardware-shaped RTD plus digital loopback stories using the existing
  `EK1100 -> EL1809 -> EL2809 -> EL3202` model

When in doubt, ask:

> "What failure would an industrial user most want to know about before trusting
> this master on a real machine?"

Then write that test.

## Definition Of Done

A hardening scenario is done when all of this is true:

- the `.md` scenario note and `_test.exs` file match
- the test fails before the relevant fix and passes after it
- the test checks the degraded interval, not just final recovery
- the test uses deterministic simulator timing where possible
- `Expect.simulator_queue_empty/0` passes when the scenario is complete
- the targeted simulator test passes
- the broader simulator suite still passes

If the scenario models a real ring risk, add a hardware promotion note that
says which bench script or manual run should confirm it.

## Core Commands

Run the smallest thing first:

```bash
mix test test/integration/simulator/NN_case_name_test.exs
mix test test/integration/simulator
ETHERCAT_INTERFACE=<eth-iface> mix test test/integration/hardware/ring_test.exs
```

## Promotion To Real Hardware

Use real hardware after the simulator case is already valuable and stable.

The current 4-slave ring is:

```text
EK1100 coupler (pos 0)
  └── EL1809  16-ch 24V digital input   (slave :inputs,  station 0x1001)
  └── EL2809  16-ch 24V digital output  (slave :outputs, station 0x1002)
  └── EL3202  2-ch PT100 RTD            (slave :rtd,     station 0x1003)
```

Each EL2809 output channel is wired to the matching EL1809 input channel.

Use hardware to answer questions the simulator cannot fully settle:

- does the real bench show the same recovery shape?
- does transport timing on an actual NIC change the failure meaning?
- does the RTD terminal or loopback wiring reveal drift from the simulated model?

## Running A Hardware Script

```bash
MIX_ENV=test mix run test/integration/hardware/scripts/<script>.exs --interface <eth-iface> [flags]
```

Requirements:

- `MIX_ENV=test` is required because the scripts reuse
  `test/integration/support/`
- ExUnit hardware tests use `ETHERCAT_INTERFACE`; these scripts take
  `--interface` directly
- raw Ethernet socket access still requires `CAP_NET_RAW` or root

Recommended promotion scripts:

- `scan.exs` - verify ring identity and station assignment
- `fault_tolerance.exs` - exercise crash, disconnect, and reconnect behavior
- `watchdog_recovery.exs` - validate safe-state and watchdog recovery
- `multi_domain.exs` - exercise split-domain behavior and shared timing edges
- `dc_sync.exs` - inspect DC lock and runtime sync behavior

Lower-level probes under `test/integration/hardware/scripts/` remain useful for
bench-specific investigation, but new robustness work should normally begin in
the simulator.

## Final Instruction

Do not write tests that merely prove the master works when everything is fine.
Write tests that make it earn trust.
