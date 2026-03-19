## Scenario

Redundant secondary-port disconnect must keep a `10ms` cyclic domain healthy
without stretching each degraded exchange past the configured frame timeout.

## Real-World Analog

The master backup port is physically unplugged while the redundant ring is
already operational. Primary ingress should keep the full ring reachable, and
the bus must not stall behind an overlong merge wait on each one-sided bounce.

## Expected Master Behavior

- Master stays operational after the secondary disconnect.
- Domain cycles remain healthy at the default `10ms` cycle time.
- Loopback PDO I/O continues over the degraded primary-only path.
- No manual timeout retuning or `100ms` cycle increase is required.

## Actual Behavior Today

Before the fix, `Link.Redundant` replaced the original frame timeout with a
fresh fixed `25ms` merge window after the first degraded bounce arrived.

That made a one-sided degraded exchange take `25ms+` even when the configured
frame timeout was `10ms`, so the bus could appear stuck in `:awaiting` while
the master stayed nominally operational.

## Fault Description

- Expected behavior: the merge window should only consume the remaining frame
  timeout budget of the in-flight exchange.
- Actual behavior: the first partial arrival reset the timeout to a fixed
  `25ms`, extending degraded exchanges well past the configured frame timeout.
- Visible runtime impact: a `10ms` redundant ring could stall after secondary
  disconnect, while the same setup looked healthy at `100ms`.
- Suspected broken layer and why: `EtherCAT.Bus.Link.Redundant`, because
  `:waiting_merge` overwrote the in-flight timeout budget.

## Repair Plan

1. Bound the merge wait to the remaining frame-time budget of the current
   exchange.
2. Add a latency-sensitive bus regression for one-sided bounce replies.
3. Add a redundant raw integration scenario for secondary disconnect at
   `10ms`.

## Test Shape

1. Boot the maintained redundant raw simulator ring at the default `10ms`
   domain cycle with a `10ms` bus frame timeout.
2. Verify loopback PDO I/O while healthy.
3. Disconnect the master secondary port.
4. Assert the master stays operational, the domain stays healthy, and loopback
   PDO I/O still succeeds on the degraded primary-only path.

## Simulator API Notes

- Current API was missing a secondary-toggle helper; the fix uses
  `RedundantSimulatorRing.disconnect_secondary!/0` and
  `reconnect_secondary!/0`.
