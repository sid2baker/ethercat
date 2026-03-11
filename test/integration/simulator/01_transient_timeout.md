## Scenario

Transient full-response timeout during cyclic operation.

## Real-World Analog

A flaky cable, NIC pause, switch hiccup, or host scheduling stall causes the
master to miss one or more whole cyclic replies.

## Expected Master Behavior

- Domain should mark the cycle invalid with `:timeout`.
- Master should move from `:operational` to `:recovering`.
- No slave-local fault should be blamed, because the fault is transport-wide.
- Once replies resume, the domain should recover and the master should return
  to `:operational`.

## Actual Behavior Today

Observed with `Simulator.inject_fault({:next_exchanges, 10, :drop_responses})`:

- domain enters invalid cycle health with `last_invalid_reason: :timeout`
- master enters `:recovering`
- `EtherCAT.slaves/0` keeps all slave faults as `nil`
- after the counted fault window is exhausted, the domain becomes healthy again
  and the master returns to `:operational`

This matches the intended behavior.

## Test Shape

1. boot the simulated ring to `:operational`
2. inject `{:next_exchanges, 10, :drop_responses}`
3. assert `EtherCAT.state/0 == :recovering`
4. assert `EtherCAT.domain_info(:main).last_invalid_reason == :timeout`
5. assert the domain becomes healthy and the master returns to `:operational`

## Simulator API Notes

Current API is now enough for both sticky and counted timeout faults.
