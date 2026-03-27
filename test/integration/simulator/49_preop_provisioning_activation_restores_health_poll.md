## Scenario

The PREOP-first provisioning flow should restore runtime health polling when a
slave is later configured for `OP` and activated.

## Real-World Analog

A commissioning tool boots the full ring to `PREOP`, adjusts discovered slave
configs through `EtherCAT.Provisioning.configure_slave/2`, then calls
`EtherCAT.Provisioning.activate/0` to start runtime operation. Slaves that were
initially held in startup `PREOP` should still regain their normal runtime
watchdog behavior once they are activated to `OP`.

## Expected Master Behavior

- A PREOP-first session should reach `:preop_ready` without background polling.
- Reconfiguring a slave from `target_state: :preop` to `target_state: :op`
  should restore its configured runtime health poll before activation.
- After activation, disconnecting a non-domain `OP` slave should become a
  visible slave-local `{:down, :no_response}` fault while the master stays
  `:operational`.
- When the disconnect clears, the slave should heal back to `:op`.

## Historical Regression

The reproducer exposed two linked runtime faults in the PREOP-first
provisioning path:

- `configure_slave(..., target_state: :op)` updated the master's stored slave
  config, but target-state-only changes did not count as local PREOP
  reconfiguration work, so the slave process kept the startup-suppressed
  `health_poll_ms: nil` instead of restoring its configured runtime watchdog.
- `activate/0` from `:preop_ready` advanced the ring to `OP`, but it left the
  master's `desired_runtime_target` at `:preop`, so later recovery converged
  back to `:preop_ready` even after a successful provisioning activation.

## Fault Classification

- master/domain/slave behavior is wrong

## API Note

- no API change needed

## Fault Description

- Expected behavior: the README provisioning flow should restore the slave's
  configured health poll when a PREOP-held slave is later activated to `OP`.
- Actual behavior: the target-state update alone did not push the restored
  `health_poll_ms` back into the slave runtime, and once that was fixed the
  master still treated post-activation recovery as a `:preop` session because
  `activate/0` from `:preop_ready` never restored `desired_runtime_target: :op`.
- Visible runtime impact: disconnected mailbox-only slaves either stayed
  silently fault-free after activation or, once health polling was restored,
  forced recovery back to `:preop_ready` instead of healing back to
  `:operational`.
- Suspected broken layer and why: master PREOP provisioning and activation
  state management, because the target-state change was not treated as local
  reconfiguration work and the activation boundary did not switch the desired
  runtime target back to `:op`.

## Repair Plan

1. Keep the new integration test as the reproducer.
2. Treat target-state-only provisioning updates as local PREOP reconfigure work
   so the slave runtime regains its configured `health_poll_ms`.
3. Restore `desired_runtime_target: :op` when `activate/0` is called from
   `:preop_ready`.
4. Add cheap unit coverage for both configuration-diff and activation-target
   behavior.
5. Rerun the targeted scenario and the broader simulator suite.

## Test Shape

1. Boot a segmented ring with all slaves intentionally held in `PREOP`.
2. Reconfigure the discovered slaves to `target_state: :op` through
   `EtherCAT.Provisioning.configure_slave/2`.
3. Activate the session and wait for `:operational`.
4. Disconnect the mailbox-only slave long enough for runtime health polling.
5. Assert the master stays `:operational`, the mailbox fault becomes visible,
   and the slave later heals back to `:op`.

## Simulator API Notes

- Current simulator fault builders are enough through `Fault.disconnect/1`.
