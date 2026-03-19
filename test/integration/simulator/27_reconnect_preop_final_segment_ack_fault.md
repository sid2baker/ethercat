## Scenario

A mailbox-capable slave disconnects during normal operation, reconnects, and
then the final segmented download acknowledgement comes back malformed while
rerunning driver PREOP mailbox configuration.

## Real-World Analog

A non-critical mailbox device drops off the ring briefly. Link returns, the
slave rebuilds locally back to PREOP, the device accepts the full PREOP CoE
startup download, but the final acknowledgement returns malformed protocol data
after the object write is already committed.

## Expected Master Behavior

- Healthy PDO domains should stay operational while the mailbox-only slave is
  degraded.
- The mailbox slave fault should become a precise
  `{:preop, {:preop_configuration_failed, ...}}` entry with the retained final
  segmented-download parser error from the mailbox helper.
- The mailbox object should already reflect the committed write, even though
  the helper returned an error for the malformed final acknowledgement.
- Clearing the injected malformed final-ack fault should allow the master's
  retry loop to rerun PREOP configuration and return the slave to OP without
  restarting the whole session.

## Test Shape

1. boot a healthy coupler + digital I/O ring with one extra mailbox-only slave
2. inject a reconnect window for that slave plus a malformed final segmented
   download acknowledgement during its PREOP rebuild download
3. assert the main domain stays healthy while the mailbox slave lands in PREOP
   with the retained configuration error
4. verify the mailbox object already contains the committed write
5. clear simulator faults
6. assert the master's retry loop reruns PREOP configuration and the mailbox
   slave returns to OP automatically

## Simulator API Notes

Current simulator fault builders are enough for this through:

- `Fault.script/1` with repeated `Fault.disconnect/1` steps
- `Fault.mailbox_protocol_fault/5`
- `Fault.after_milestone/2` with `Fault.mailbox_step/3`

If this fails, the bug is in reconnect-time PREOP recovery, not the simulator
fault surface.
