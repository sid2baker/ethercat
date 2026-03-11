## Scenario

A single reusable fault script mixes exchange faults, a milestone wait, and a
later slave-local mutation.

## Real-World Analog

A ring experiences a short transport/runtime disturbance, stabilizes for a
known healthy window, and only then one slave retreats to `SAFEOP`.

## Expected Master Behavior

- The initial exchange-fault portion of the script should drive the master into
  `:recovering`.
- Once those exchanges clear, the ring should return to `:operational` while
  the remaining script waits on a health milestone.
- The later `SAFEOP` retreat should remain a slave-local fault path.
- The master should retry the affected slave back to `:op` and restore healthy
  PDO traffic.

## Actual Behavior Today

Observed with:

- `Simulator.inject_fault({:fault_script, List.duplicate(:drop_responses, 6) ++ List.duplicate({:wkc_offset, -1}, 4) ++ [{:wait_for_milestone, {:healthy_polls, :outputs, 12}}, {:retreat_to_safeop, :outputs}]})`

- the master first enters `:recovering`
- the remaining script becomes visible through `Simulator.info/0` while waiting
  on healthy polls
- once the outputs slave has passed enough healthy polls, it retreats to
  `SAFEOP`
- the master keeps the fault slave-local, retries `:op`, and returns to a
  healthy ring without manual fault clearing

## Test Shape

1. boot the ring with health polling enabled on the affected slave
2. inject one combined fault script
3. assert the master first recovers from the exchange-fault prefix
4. assert the remaining script waits on healthy polls
5. assert the later `SAFEOP` retreat appears and is retried away
6. assert PDO traffic is healthy again after recovery

## Simulator API Notes

`{:fault_script, steps}` can now carry milestone waits directly through
`{:wait_for_milestone, milestone}`.

Still worth adding later:

- malformed segmented CoE payloads, like invalid segment padding or unexpected
  segment response bodies
