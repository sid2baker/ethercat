## Scenario

An otherwise operational session may intentionally keep a mailbox-only slave in
`PREOP`. Runtime fault handling should still monitor that held slave, but any
reconnect should return it to its configured `PREOP` target instead of
promoting it to `OP`.

## Real-World Analog

A live machine keeps PDO participants in `OP` while one service-only slave
stays in `PREOP` for provisioning or diagnostics. If that service slave is
briefly unplugged, the runtime should expose the slave-local fault without
degrading the running domains, and when the slave returns it should resume the
same held `PREOP` role.

## Expected Master Behavior

- The master should stay `:operational` while PDO domains remain healthy.
- The held mailbox slave should still use health polling during runtime.
- A disconnect should become a visible slave-local fault.
- When the slave returns, it should recover back to `:preop`, not `:op`.

## Historical Regression

With inputs and outputs active in `OP` and the mailbox slave intentionally held
in `PREOP`, disconnecting `:mailbox` exposed two linked problems:

- startup treated any `target_state: :preop` slave like a configuration-only
  session and suppressed its health poll entirely, so the disconnect stayed
  invisible while the master remained `:operational`
- once runtime polling was restored, the reconnect path used the session-wide
  `:op` target instead of the mailbox slave's configured `:preop` target, so a
  healed mailbox slave was immediately promoted to `OP`

That made mixed target-state sessions treat held service slaves as if they were
either out-of-band or globally activatable.

## Fault Classification

- master/domain/slave behavior is wrong

## API Note

- no API change needed

## Fault Description

- Expected behavior: a held `PREOP` slave inside an otherwise operational
  session should be monitored like a runtime slave, but any reconnect should
  honor that slave's configured target state.
- Actual behavior: startup suppressed the held slave's health poll because its
  configured target was `:preop`, and once polling was restored the reconnect
  retry promoted the slave to `:op` because it used the global runtime target.
- Visible runtime impact: the mailbox slave disconnect either stayed invisible
  or healed into the wrong AL state, so mixed `OP` + held `PREOP` sessions
  could not trust slave-local fault visibility or target-state isolation.
- Suspected broken layer and why: master startup/recovery target selection,
  because both the startup poll policy and the reconnect retry target were
  derived from session-wide intent without preserving the held slave's own
  configured target.

## Repair Plan

1. Keep the new integration test as the reproducer.
2. Verify whether the failure is missing health polling, wrong reconnect
   target selection, or both.
3. Patch the smallest honest master/slave runtime layer so mixed target-state
   sessions keep runtime visibility without promoting held `PREOP` slaves.
4. Rerun the targeted scenario and the broader simulator suite.

## Test Shape

1. Boot a segmented ring with PDO slaves active in `OP`.
2. Keep the mailbox-only slave intentionally in `PREOP` with health polling
   configured.
3. Disconnect the held mailbox slave long enough for runtime polling to notice.
4. Assert the master stays `:operational` while the slave fault becomes
   visible.
5. Let the disconnect clear and assert the mailbox slave returns to `:preop`.

## Simulator API Notes

- Current simulator fault builders are enough through `Fault.disconnect/1`.
