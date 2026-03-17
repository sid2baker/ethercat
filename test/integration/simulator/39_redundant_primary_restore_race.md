## Scenario

Redundant primary veth restore must not invalidate domain cycles or trigger
master recovery after degraded single-port operation.

## Real-World Analog

Physical cable reconnection on the primary port after a temporary disconnect.
The ring transitions from degraded (secondary-only) back to full redundant
operation. During the transition, the slave near primary detects link-up and
may divert frames before the master NIC is ready.

## Expected Master Behavior

- Master stays operational throughout disconnect and reconnect.
- Domain cycles remain healthy (no `:timeout` or `:transport_miss` events).
- No master `:recovering` transitions after reconnect.
- Bus info reports `type: :redundant` throughout.

## Actual Behavior Today

Secondary disconnect/reconnect works cleanly. Primary reconnect may cause
transient timeouts on some NIC hardware due to PHY link-up timing differences
between the two ports.

## Test Shape

1. Boot full operational redundant ring on veth pairs.
2. Verify loopback I/O works.
3. Disconnect primary veth.
4. Assert master stays operational, domain stays healthy.
5. Reconnect primary veth.
6. Assert no domain invalid or master recovering events after reconnect.
7. Assert loopback I/O resumes.

## Simulator API Notes

- Current API is enough (`RedundantSimulatorRing.disconnect_primary!/0`,
  `reconnect_primary!/0`).
