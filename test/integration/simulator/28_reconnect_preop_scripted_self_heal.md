## Scenario

A mailbox-capable slave disconnects during normal operation, reconnects, and
then hits a one-shot mailbox protocol fault during the first PREOP rebuild
attempt. The simulator fault script should fully drain, and a later master
retry should self-heal without manual `clear_faults/0`.

## Real-World Analog

A device briefly drops off the ring, link comes back, and the first retry of a
segmented PREOP mailbox write times out because of a transient mailbox hiccup.
The next retry succeeds once the transient fault is gone.

## Expected Master Behavior

- Healthy PDO domains should stay operational while the mailbox-only slave is
  degraded.
- The mailbox slave fault should become a precise
  `{:preop, {:preop_configuration_failed, ...}}` entry after the first retry.
- The simulator fault queue should already be empty once that failure is
  retained, proving the remaining recovery work belongs to the master retry
  loop, not a sticky fault window.
- The master's retry loop should rerun PREOP configuration and return the
  mailbox slave to OP automatically without manual simulator cleanup.

## Test Shape

1. boot the segmented mailbox ring to OP
2. inject a single fault script containing:
   - a reconnect window
   - a mailbox-step milestone wait
   - one malformed download-segment response on the first rebuild attempt
3. assert the mailbox slave lands in PREOP with a retained configuration error
   while domains stay healthy and the simulator queue is already drained
4. assert a later retry returns the slave to OP and the startup object matches
   the expected segmented blob

## Simulator API Notes

This scenario exercises the current builder API rather than adding a new
surface:

- `Fault.script/1`
- `Fault.wait_for/1`
- `Fault.mailbox_step/3`
- `Fault.mailbox_protocol_fault/5`

If this had failed, the likely issue would have been the master's reconnect
PREOP retry loop, not the simulator API.
