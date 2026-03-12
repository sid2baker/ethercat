## Scenario

A mailbox-capable slave disconnects during normal operation, reconnects, and
then hits two different mailbox protocol faults on successive PREOP rebuild
retries before eventually recovering without manual simulator cleanup.

## Real-World Analog

After a transient disconnect, the first reconnect retry loses a segmented
mailbox response, and a later retry hits a malformed mailbox response from the
same device before the next retry finally succeeds.

## Expected Master Behavior

- Healthy PDO domains should stay operational while the mailbox-only slave is
  degraded.
- The mailbox slave should retain the first PREOP configuration failure, then
  later retain the second distinct PREOP configuration failure on the next
  retry.
- The simulator should show that the first failure does not require manual
  cleanup because the remaining scripted fault is still waiting on a later
  mailbox milestone.
- Once the second scripted fault fires and drains, a later master retry should
  rerun PREOP configuration and return the mailbox slave to OP automatically.

## Test Shape

1. boot the segmented mailbox ring to OP
2. inject a reconnect fault script with:
   - a disconnect window
   - one timeout-inducing segmented response drop on the first rebuild
   - a second wait on the next successful download-init step after the first
     retained failure
   - one malformed segmented response on the later rebuild
3. assert the first retained PREOP failure while the second scripted fault is
   still queued
4. assert the second retained PREOP failure once the script drains
5. assert a later retry returns the mailbox slave to OP with the expected blob

## Simulator API Notes

The current builder API is enough for this through:

- `Fault.script/1`
- `Fault.wait_for/1`
- `Fault.mailbox_step/3`
- `Fault.mailbox_protocol_fault/5`

This scenario is mainly about proving retry sequencing and observability, not
adding a new fault surface.
