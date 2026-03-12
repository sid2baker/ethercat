## Scenario

A mailbox slave reconnects, fails its PREOP rebuild on a scripted segmented
download timeout, and remains degraded. While that retained mailbox fault is
still present, a different PDO-participating slave retreats from `:op` to
`:safeop`.

## Real-World Analog

Two independent problems overlap:

- a smart mailbox device reconnects but temporarily cannot finish its PREOP
  configuration sequence
- a separate output device detects a local condition and drops to `:safeop`

This is a realistic "messy plant" window where the master must keep the fault
ownership clear instead of collapsing everything into one generic degraded
state.

## Expected Master Behavior

- The mailbox slave should retain its reconnect PREOP failure as a slave-local
  fault and stay in `:preop`.
- The output slave retreat should be detected separately as
  `{:retreated, :safeop}`.
- The master should remain `:operational`.
- Domain cycling should remain healthy because both failures are slave-local,
  not transport-wide.
- The output slave should recover on the normal slave-fault retry path.
- The mailbox slave should later recover on its PREOP retry path without a full
  restart.

## Actual Behavior Today

Observed with:

1. a scripted reconnect mailbox timeout via `Fault.script/1`
2. an explicit later `Fault.retreat_to_safeop(:outputs)` after the mailbox
   fault is already retained

The runtime currently behaves as intended:

- the mailbox slave fault becomes
  `{:preop, {:preop_configuration_failed, {:mailbox_config_failed, ...}}}`
- the output slave fault later becomes `{:retreated, :safeop}`
- the master stays `:operational`
- the domain stays healthy
- both faults clear on their existing retry paths

## Test Shape

1. boot the segmented mailbox ring in `:op`
2. inject a reconnect PREOP mailbox fault script
3. wait until the mailbox fault is retained
4. inject `Fault.retreat_to_safeop(:outputs)` while the mailbox fault is still
   present
5. assert both slave faults coexist while the master stays `:operational`
6. assert both faults later clear and both slaves return to `:op`
7. assert the trace captured both fault lifecycles independently
