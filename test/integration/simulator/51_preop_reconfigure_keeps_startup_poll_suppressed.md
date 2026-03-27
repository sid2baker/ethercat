## Scenario

A startup-held `:preop_ready` provisioning session should keep background
health polling suppressed for slaves that are reconfigured but still
intentionally left in `PREOP`.

## Real-World Analog

A commissioning tool boots the ring to `PREOP`, tweaks one slave's local
configuration through `EtherCAT.Provisioning.configure_slave/2`, but does not
activate anything yet. The session is still configuration-only, so a later
disconnect should not turn into a runtime fault just because one PREOP
reconfigure happened.

## Expected Master Behavior

- A startup-held all-`PREOP` session should reach `:preop_ready` without
  background polling.
- Reconfiguring a slave while keeping its target state at `:preop` should not
  arm runtime health polling yet.
- A later disconnect in that same configuration-only session should leave the
  master at `:preop_ready` with no tracked slave fault.

## Historical Regression

The reproducer showed that a plain PREOP reconfigure in a startup-held
`:preop_ready` session could accidentally turn the session into a runtime-like
watchdog regime:

- `configure_slave(..., target_state: :preop, health_poll_ms: 20)` updated the
  master's stored config and also pushed that positive `health_poll_ms` into
  the live slave runtime even though the whole session was still intentionally
  held in startup `PREOP`.
- Once the live slave runtime had that positive poll interval, the PREOP
  reconfigure path immediately armed the health poll timeout, so a later
  disconnect became a critical `:down` fault instead of staying invisible until
  activation.

## Fault Classification

- master/domain/slave behavior is wrong

## API Note

- no API change needed

## Fault Description

- Expected behavior: PREOP reconfiguration inside a configuration-only
  `:preop_ready` session should preserve the startup health-poll suppression
  until activation begins.
- Actual behavior: a simple `configure_slave/2` update while staying targeted
  at `:preop` armed background health polling, so disconnecting the same slave
  immediately moved the master from `:preop_ready` to `:recovering`.
- Visible runtime impact: configuration-only provisioning sessions lost the
  isolation guaranteed by scenario 47; a reconfigured PREOP slave could start
  faulting like an active runtime participant before any explicit activation.
- Suspected broken layer and why: master PREOP configuration handoff, because
  the master passed the stored positive `health_poll_ms` back into the live
  slave runtime even though the session target was still startup `:preop`.

## Repair Plan

1. Keep the new integration test as the reproducer.
2. Verify whether `configure_slave/2` in `:preop_ready` arms background polling
   for a slave that remains targeted at `:preop`.
3. Patch the master PREOP config path so startup-held PREOP sessions keep the
   live slave watchdog suppressed until activation, while still storing the
   requested config for later runtime use.
4. Add cheap unit coverage for the actual slave configure payload used by the
   master PREOP path.
5. Rerun the targeted scenario and the broader simulator suite.

## Test Shape

1. Boot a tiny ring intentionally held in `PREOP`.
2. Reconfigure one slave while keeping `target_state: :preop`.
3. Disconnect that slave.
4. Assert the master stays `:preop_ready` and the slave fault stays `nil`.

## Simulator API Notes

- Current simulator fault builders are enough through `Fault.disconnect/1`.
