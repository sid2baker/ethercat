## Scenario

A PDO-participating slave reports an AL error latch while still answering
health-poll reads in `OP`.

## Real-World Analog

A slave hits a local AL-status fault such as invalid output configuration or a
device-local watchdog condition, but it still responds on the bus and does not
physically disappear.

## Expected Master Behavior

- The slave health poll should detect the latched AL error and surface the
  fault through telemetry.
- The slave should retreat cleanly to `SAFEOP` instead of being treated as
  disconnected.
- The master should stay `:operational` while the retained fault remains
  slave-local.
- The normal retry path should request `OP` again and return the slave to
  healthy operation once the AL latch is acknowledged.

## Actual Behavior Today

Observed with `Simulator.inject_fault(Fault.latch_al_error(:outputs, 0x001D))`
and `output_health_poll_ms: 20`:

- the outputs slave emits a health-fault telemetry event with AL state `0x08`
  and error code `0x001D`
- the outputs slave fault becomes `{:retreated, :safeop}`
- the master remains `:operational`
- the domain remains healthy
- after the master's slave-fault retry interval, it requests `:op` again, the
  outputs slave returns to `:op`, and the slave fault clears

This matches the intended slave-local recovery policy.

## Test Shape

1. boot the ring with health polling enabled on the affected slave
2. inject `Fault.latch_al_error(:outputs, 0x001D)`
3. assert the health-fault telemetry event
4. assert the slave fault becomes `{:retreated, :safeop}`
5. assert the master remains `:operational` and the domain remains healthy
6. assert the fault later clears and the slave returns to `:op`

## Simulator API Notes

Current API is enough through `Fault.latch_al_error/2`.

No API change needed.
