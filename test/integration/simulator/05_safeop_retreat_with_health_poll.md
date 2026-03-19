## Scenario

One PDO-participating slave retreats from `:op` to `:safeop`, with slave
health polling enabled. The same scenario file also guards the later
disconnect-while-held path.

## Real-World Analog

A drive or smart I/O device detects a local fault, drops out of operational
state, but remains electrically present on the segment.

## Expected Master Behavior

- The slave health poll should detect the AL-state mismatch and emit a slave
  health fault.
- Master should track the slave as `{:retreated, :safeop}`.
- This should stay a slave-local fault path, not a full master
  `:recovering` transition.
- The master should retry requesting `:op` for that slave and clear the fault
  once the slave returns to operational.
- Domain cycling should remain healthy while the slave is still present and
  contributing WKC.
- If the same slave later disconnects while already held in `:safeop`, the
  health poll should still transition it to `:down` and then follow the normal
  reconnect-healing path.

## Actual Behavior Today

Observed with `Simulator.inject_fault({:retreat_to_safeop, :outputs})` and
`output_health_poll_ms: 20`:

- the outputs slave emits a health-fault telemetry event with AL state `0x04`
- the outputs slave fault becomes `{:retreated, :safeop}`
- the master remains `:operational`
- the domain remains healthy
- after the master's slave-fault retry interval, it requests `:op` again,
  the outputs slave returns to `:op`, and the slave fault clears

This matches the intended slave-local recovery policy.

## Test Shape

### Test A: SAFEOP retreat stays slave-local

1. boot the ring with health polling enabled on the affected slave
2. inject `{:retreat_to_safeop, :outputs}`
3. assert the health-fault telemetry event
4. assert the slave fault becomes `{:retreated, :safeop}`
5. assert the master remains `:operational` and the domain remains healthy
6. assert the fault later clears and the slave returns to `:op`

### Test B: SAFEOP disconnect still becomes `:down`

1. first drive the slave to `:safeop`
2. inject a bounded full disconnect while it is still held there
3. assert the slave fault changes from `{:retreated, :safeop}` to
   `{:down, :no_response}`
4. assert the master follows the normal recovery path and later returns the
   slave to `:op`

## Simulator API Notes

Current API is enough, including milestone scheduling through
`{:after_milestone, {:healthy_polls, slave_name, count}, fault}`.
