## Scenario

Combined datagram/runtime fault script during cyclic operation.

## Real-World Analog

A segment sees a short transport timeout, then degraded traffic, then one slave
drops briefly before reconnecting.

## Expected Master Behavior

- The master should enter `:recovering` once the scripted faults start to affect
  cyclic exchange.
- A disconnected PDO slave should still surface as a slave-local
  `{:down, :disconnected}` fault when health polling is enabled.
- Once the script is exhausted and the slave reconnects, the master should
  return to `:operational` without a restart.

## Actual Behavior Today

Observed with:

`Simulator.inject_fault({:fault_script, List.duplicate(:drop_responses, 6) ++ List.duplicate({:wkc_offset, -1}, 4) ++ List.duplicate({:disconnect, :outputs}, 30)})`

- the master enters `:recovering`
- the outputs slave later becomes `{:down, :disconnected}`
- after the script is exhausted, the outputs slave reconnects, returns to `:op`,
  and the master returns to `:operational`
- PDO traffic works again after recovery

## Test Shape

1. boot the ring with health polling enabled on the affected slave
2. inject one combined fault script
3. assert recovery and the outputs slave-down fault
4. assert the script queue drains
5. assert the slave reconnects and the system returns to `:operational`
6. assert PDO traffic still works

## Simulator API Notes

Current API is enough for basic combined sequential fault scripts.
