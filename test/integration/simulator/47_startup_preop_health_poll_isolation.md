## Scenario

Slaves intentionally started and held in `PREOP` should not background
health-poll themselves into runtime recovery.

## Real-World Analog

A configuration-only session boots the ring to `PREOP` so tooling can run SDO
reads/writes or capture device state before any OP activation. A slave may be
temporarily unplugged during that window, but the session should stay in its
explicit `PREOP` hold mode until the caller actively transitions or probes it.

## Expected Master Behavior

- Starting the master with all slaves targeted to `:preop` should settle in
  `:preop_ready`.
- The default `health_poll_ms` should not turn a startup-held `PREOP` slave
  into a background runtime watchdog.
- Disconnecting one PREOP-held slave and waiting past the default `250ms`
  should not move the master to `:recovering`.
- The disconnected slave should not be marked `{:down, :no_response}` unless a
  later explicit transition or probe requires that visibility.

## Historical Regression

With all slaves started to `:preop` and the default `health_poll_ms=250`,
disconnecting `:outputs` causes the slave runtime to poll AL status while still
held in `PREOP`.

After roughly one poll interval:

- the outputs slave reports `health poll: wkc=0 — entering :down`
- the master tracks `{:down, :no_response}` for `:outputs`
- the master leaves `:preop_ready` and enters `:recovering`

This makes a startup-held PREOP configuration session behave like an active
runtime recovery session.

This scenario now guards the fixed behavior: startup `:init -> :preop` no
longer arms background health polling, while runtime-held `PREOP` continues to
use the existing health-check path.

## Fault Classification

- master/domain/slave behavior is wrong

## API Note

- no API change needed

## Fault Description

- Expected behavior: default health polling should not run against slaves that
  are intentionally being held in startup `PREOP`.
- Actual behavior: `PREOP` entry schedules the same health-poll action used for
  runtime-held states, so a disconnected slave is marked `:down` after the
  default `250ms`.
- Visible runtime impact: `EtherCAT.state/0` changes from `:preop_ready` to
  `:recovering` during configuration-only sessions, and the master reports a
  runtime slave fault even though no runtime activation was requested.
- Suspected broken layer and why: slave runtime polling/health handling, because
  `preop_enter_actions/1` always schedules health polling without
  distinguishing startup-held `PREOP` from later runtime-held `PREOP`.

## Repair Plan

1. Keep the new integration test as the reproducer.
2. Distinguish startup-held `PREOP` from runtime-held `PREOP` in the slave
   runtime so only the latter keeps background health polling.
3. Preserve existing `SAFEOP` and runtime recovery behavior for already-active
   sessions.
4. Rerun the targeted scenario and the broader simulator suite.

## Test Shape

1. Boot the smallest maintained simulator ring that still reproduces the issue:
   coupler plus one output slave, both targeted to `:preop`.
2. Confirm the master reports `:preop_ready`.
3. Inject a disconnect on the PREOP-held output slave.
4. Wait longer than the default `250ms` health-poll interval.
5. Assert the master stays `:preop_ready` and no slave fault is tracked.

## Simulator API Notes

- Current simulator fault builders are enough through `Fault.disconnect/1`.
