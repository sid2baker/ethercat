## Scenario

A mailbox slave reconnects, fails its PREOP rebuild on a segmented download
timeout, and retains that PREOP fault. That retained mailbox-fault transition
arms a counted output disconnect, and the resulting master `:recovering` entry
then arms a follow-up `SAFEOP` retreat on a different PDO slave.

## Real-World Analog

This models a realistic stacked field failure:

- a smart mailbox device comes back after a brief drop but its first PREOP
  rebuild loses a mailbox segment
- an output slice later drops out for a bounded exchange window, forcing the
  master into `:recovering`
- while the master is recovering that transport fault, another process-data
  slave retreats to `SAFEOP`

The important part is the shape of the recovery story. Real systems do fail in
clusters, and the master should keep each fault visible instead of collapsing
them into one vague unhealthy interval.

## Expected Master Behavior

- The mailbox reconnect PREOP failure should remain retained as a slave-local
  fault in `:preop`.
- That retained mailbox-fault transition should synchronously arm the counted
  output disconnect.
- The output disconnect should force the master into `:recovering`.
- The master `:recovering` entry should synchronously arm the follow-up
  `SAFEOP` retreat on the inputs slave.
- The output slave should heal first, allowing the master back to
  `:operational` while the mailbox PREOP fault and the inputs `SAFEOP` retreat
  still remain visible.
- The inputs and mailbox slaves should later recover on their existing retry
  paths without a full session restart.

## Test Shape

1. boot the segmented mailbox ring in `:op`
2. arm a counted output disconnect on the mailbox retained-fault transition
3. arm an inputs `SAFEOP` retreat on master `:recovering` entry
4. inject the reconnect PREOP mailbox fault script
5. assert both telemetry triggers matched and injected
6. assert the output disconnect drives the master into `:recovering`
7. assert outputs heal first while mailbox PREOP and inputs `SAFEOP` faults
   remain retained
8. assert the inputs and mailbox retry paths later heal too
