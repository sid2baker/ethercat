## Scenario

Exchange-fault recovery followed by a slave-local fault that waits on explicit
health-poll milestones instead of wall-clock delay.

## Real-World Analog

A ring stabilizes after a transient transport/runtime disturbance, then a
device later retreats to `SAFEOP` only after it has been observed healthy for a
few polls.

## Expected Master Behavior

- The initial exchange fault should drive the master into `:recovering`.
- Once the exchange fault window clears, the master should return to
  `:operational`.
- The later `SAFEOP` retreat should remain a slave-local fault path.
- The master should retry the affected slave back to `:op` and restore healthy
  PDO traffic.

## Actual Behavior Today

Observed with:

- `Simulator.inject_fault({:exchange_script, List.duplicate(:drop_responses, 6) ++ List.duplicate({:wkc_offset, -1}, 4)})`
- `Simulator.inject_fault({:after_milestone, {:healthy_polls, :outputs, 12}, {:retreat_to_safeop, :outputs}})`

- the master first enters `:recovering`
- the simulator keeps the scheduled fault visible through `waiting_on` and
  `remaining`
- once the outputs slave has passed enough healthy polls, it retreats to
  `SAFEOP`
- the master keeps the fault slave-local, retries `:op`, and returns to a
  healthy ring without manual fault clearing

## Test Shape

1. boot the ring with health polling enabled on the affected slave
2. inject a short exchange fault script
3. schedule a `SAFEOP` retreat after `N` healthy polls on the outputs slave
4. assert the master first recovers from the exchange faults
5. assert the milestone-scheduled fault stays pending while the ring is healthy
6. assert the delayed slave-local fault appears and is retried away
7. assert PDO traffic is healthy again after recovery

## Simulator API Notes

Current API is now enough for milestone-aware slave-local fault scheduling
through `{:after_milestone, {:healthy_polls, slave_name, count}, fault}`.

Still worth adding later:

- milestone steps that can be embedded directly inside a single reusable script
- startup-time mailbox aborts through driver mailbox configuration
