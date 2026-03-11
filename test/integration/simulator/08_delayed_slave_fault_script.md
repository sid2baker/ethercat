## Scenario

Exchange-scoped recovery followed by a delayed slave-local fault injection.

## Real-World Analog

A ring sees a short transport/runtime disruption, stabilizes, and then one
device later retreats to `SAFEOP` due to a local condition.

## Expected Master Behavior

- The initial exchange fault should drive the master into `:recovering`.
- Once the exchange fault window clears, the master should return to
  `:operational` without manual simulator cleanup.
- The later `SAFEOP` retreat should stay a slave-local fault path.
- The master should retry the affected slave back to `:op` and clear the
  fault.

## Actual Behavior Today

Observed with:

- `Simulator.inject_fault({:exchange_script, List.duplicate(:drop_responses, 6) ++ List.duplicate({:wkc_offset, -1}, 4)})`
- `Simulator.inject_fault({:after_ms, 600, {:retreat_to_safeop, :outputs}})`

- the master first enters `:recovering`
- the delayed fault stays visible in `Simulator.info/0` while pending
- after the delay expires, the outputs slave retreats to `SAFEOP`
- the master keeps the fault slave-local, retries `:op`, and returns to a
  healthy ring without manual fault clearing

## Test Shape

1. boot the ring with health polling enabled on the affected slave
2. inject a short exchange fault script
3. schedule a delayed `SAFEOP` retreat for the outputs slave
4. assert the master first recovers from the exchange faults
5. assert the delayed fault becomes a slave-local `{:retreated, :safeop}`
6. assert the retry clears and the ring returns to healthy PDO traffic

## Simulator API Notes

Current API is now enough for mixed exchange faults plus delayed slave-local
mutations through `{:after_ms, delay_ms, fault}`. For milestone-based timing,
prefer the dedicated `09` scenario and `{:after_milestone, milestone, fault}`.

Still worth adding later:

- milestone wait steps embedded directly inside a single reusable script
- startup-time mailbox aborts through driver mailbox configuration
