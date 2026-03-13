## Scenario

A mailbox slave reconnects, fails its PREOP rebuild on a scripted segmented
download timeout, and remains degraded. While that retained mailbox fault is
still present, a PDO-participating output slave disconnects for a bounded
exchange window and later reconnects.

## Real-World Analog

Two separate issues overlap:

- a smart mailbox device reconnects but cannot finish its PREOP configuration
  sequence on the first retry
- an unrelated output terminal loses link or power briefly and later returns

This is the kind of stacked failure that should push the master through a real
recovery interval without losing track of the already-retained mailbox fault.

## Expected Master Behavior

- The mailbox slave should retain its reconnect PREOP failure as a slave-local
  fault and stay in `:preop`.
- The output disconnect should create a real master `:recovering` interval.
- The output slave should be tracked as `{:down, :disconnected}` until the
  counted disconnect window ends and reconnect succeeds.
- After the output slave heals, the master should return to `:operational`
  while the mailbox failure is still retained.
- The mailbox slave should later recover on its PREOP retry path without a full
  session restart.

## Actual Behavior Today

Observed with:

1. a scripted reconnect mailbox timeout via `Fault.script/1`
2. a later counted output disconnect via `Fault.disconnect(:outputs) |> Fault.next(30)`

The runtime behaves as intended:

- the mailbox fault is retained first
- the later output disconnect moves the master to `:recovering`
- the output reconnect clears and the master returns to `:operational`
  while the mailbox fault is still present
- a later PREOP retry heals the mailbox slave too

## Test Shape

1. boot the segmented mailbox ring in `:op`
2. inject a reconnect PREOP mailbox fault script
3. wait until the mailbox fault is retained
4. inject a counted output disconnect while the mailbox fault is still present
5. assert the output is tracked as down and the trace captures the recovery
   interval
6. assert the output recovers while the mailbox fault still remains
7. assert the mailbox fault later clears too
8. assert the trace captured the distinct master and slave fault lifecycles
