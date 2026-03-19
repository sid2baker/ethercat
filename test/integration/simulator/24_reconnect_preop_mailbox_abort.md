## Scenario

A mailbox-capable slave disconnects during normal operation, reconnects, and
then hits a deterministic SDO abort while rerunning driver PREOP mailbox
configuration.

## Real-World Analog

A non-critical mailbox device drops off the ring briefly. Link returns, the
slave rebuilds locally back to PREOP, but the device rejects one of the
driver's PREOP CoE writes during that rebuild path before it can re-enter OP.

## Expected Master Behavior

- Healthy PDO domains should stay operational while the mailbox-only slave is
  degraded.
- The mailbox slave fault should become a precise
  `{:preop, {:preop_configuration_failed, ...}}` entry instead of a generic
  transport/runtime failure.
- `EtherCAT.slave_info/1` should expose the retained PREOP configuration error.
- Clearing the injected mailbox abort should allow the master's retry loop to
  rerun PREOP configuration and return the slave to OP without restarting the
  whole session.

## Test Shape

1. boot a healthy coupler + digital I/O ring with one extra mailbox-only slave
2. inject a scripted mailbox-slave disconnect window followed by a sticky
   mailbox abort for its startup CoE write
3. assert the main domain stays healthy while the mailbox slave lands in PREOP
   with a retained configuration error
4. clear simulator faults
5. assert the master's retry loop reruns PREOP configuration and the mailbox
   slave returns to OP automatically

## Simulator API Notes

Current simulator fault builders are enough for this through:

- `Fault.script/1` with repeated `Fault.disconnect/1` steps
- `Fault.mailbox_abort/5`

The library change this scenario needs is not a new fault shape. It is a real
PREOP reconfiguration retry path after reconnect-time configuration failures.
