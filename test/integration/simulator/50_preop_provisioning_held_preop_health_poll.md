## Scenario

The PREOP-first provisioning flow should restore runtime health polling for a
discovered slave intentionally left in `PREOP` once the rest of the ring is
activated to `OP`.

## Real-World Analog

A commissioning tool boots the whole ring to `PREOP`, updates only the PDO
slaves to `target_state: :op`, and deliberately leaves a mailbox-only service
node in `PREOP` for later configuration access. Once runtime is operational,
that held-`PREOP` slave should still background-detect disconnects and recover
back to `PREOP`.

## Expected Master Behavior

- A PREOP-first session should reach `:preop_ready` without background polling.
- Activating only part of the ring to `OP` should keep the held mailbox slave
  in `PREOP` while the master reaches `:operational`.
- Once the session is operational, the held mailbox slave should regain its
  configured runtime health poll even though its target state remains `:preop`.
- A later mailbox disconnect should become a visible slave-local
  `{:down, :no_response}` fault while the master stays `:operational`.
- When the disconnect clears, the mailbox slave should heal back to `:preop`.

## Historical Regression

The reproducer exposed two linked runtime faults in the PREOP-first mixed
activation path:

- `activate/0` restored runtime targeting for the `OP` slaves, but it did not
  re-apply the configured `health_poll_ms` to slaves intentionally left in
  `PREOP`, so the held mailbox slave stayed on the startup-suppressed
  watchdog setting.
- Even once the configured `health_poll_ms` was pushed back into a live PREOP
  slave, the successful PREOP reconfigure path did not reschedule the health
  poll timeout, so the slave remained blind to disconnects until some later
  state transition happened to re-enter `:preop`.

## Fault Classification

- master/domain/slave behavior is wrong

## API Note

- no API change needed

## Fault Description

- Expected behavior: a slave intentionally left in `PREOP` during PREOP-first
  provisioning should still regain runtime health polling once the rest of the
  ring is activated to `OP`.
- Actual behavior: after mixed provisioning activation, disconnecting the held
  mailbox slave left `slave_fault(:mailbox)` at `nil`; the slave never entered
  `:down` even though the rest of the ring was already operational.
- Visible runtime impact: operational sessions with intentionally held PREOP
  slaves had a blind spot where service-node disconnects stayed invisible and
  therefore could not trigger reconnect healing back to `:preop`.
- Suspected broken layer and why: master activation and slave PREOP
  reconfiguration, because startup-suppressed `health_poll_ms` was not
  restored for held PREOP slaves during mixed activation and the PREOP
  configure path did not arm the updated health poll timeout.

## Repair Plan

1. Keep the new integration test as the reproducer.
2. Restore configured `health_poll_ms` for slaves intentionally left in
   `PREOP` when `activate/0` starts an operational session.
3. Re-arm or cancel the PREOP health poll timeout when a live PREOP slave is
   reconfigured in place.
4. Add cheap activation and slave-FSM coverage for those two smaller paths.
5. Rerun the targeted scenario and the broader simulator suite.

## Test Shape

1. Boot a segmented ring with all slaves intentionally held in `PREOP`.
2. Reconfigure only the PDO slaves to `target_state: :op`.
3. Activate the session and wait for `:operational` with the mailbox slave
   still held in `PREOP`.
4. Disconnect the mailbox-only slave long enough for runtime health polling.
5. Assert the master stays `:operational`, the mailbox fault becomes visible,
   and the slave later heals back to `:preop`.

## Simulator API Notes

- Current simulator fault builders are enough through `Fault.disconnect/1`.
