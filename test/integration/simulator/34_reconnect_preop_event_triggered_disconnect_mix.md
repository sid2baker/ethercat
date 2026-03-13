## Scenario

A mailbox slave reconnects, fails its PREOP rebuild on a scripted segmented
download timeout, and retains that PREOP fault. The retained mailbox fault
transition itself then arms a counted PDO-slave disconnect through the scenario
telemetry helper instead of an imperative mid-scenario action.

## Real-World Analog

This models a stacked recovery story where:

- a smart mailbox device reconnects but cannot finish its PREOP configuration
  on the first retry
- a second, PDO-participating output slave then drops out while the first fault
  is still retained

The important part is not just the overlap. The follow-up fault should be armed
by the real master-observed mailbox-fault transition, proving the helper layer
can compose causal trigger chains without pushing those milestones into
simulator core.

## Expected Master Behavior

- The mailbox slave should retain its reconnect PREOP failure as a slave-local
  fault and stay in `:preop`.
- That retained mailbox-fault transition should synchronously arm the counted
  output disconnect.
- The later output disconnect should create a real master `:recovering`
  interval.
- The output slave should heal first and let the master return to
  `:operational` while the mailbox PREOP fault still remains retained.
- The mailbox slave should later recover on its PREOP retry path without a
  full session restart.

## Test Shape

1. boot the segmented mailbox ring in `:op`
2. arm a counted output disconnect on the mailbox retained-fault transition via
   `Scenario.inject_fault_on_event/4`
3. inject the reconnect PREOP mailbox fault script
4. assert the mailbox fault transition matched and the follow-up disconnect was
   injected through the telemetry helper
5. assert the output disconnect becomes visible while the mailbox fault remains
   retained and the trace captures the recovery interval
6. assert the output heals first
7. assert the mailbox retry path later heals too
