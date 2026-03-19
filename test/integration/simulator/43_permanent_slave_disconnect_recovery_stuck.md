## Scenario

Regression coverage for two related runtime-healing paths:

- a silent PDO-only failure where LRW degrades but register health polling stays
  green
- a full disconnect or power-cycle where a PDO slave later returns anonymous
  and must reclaim its fixed station locally by scan position

## Real-World Analog

On CM4 hardware, a slave loses PDO processing, power, or cable temporarily.

## Historical Regression

Older runtime behavior could get stuck because reconnect healing depended on the
old fixed station and master-side orchestration. A power-cycled slave could
return at station `0x0000`, never be rebuilt for PDO again, and leave the
master stuck in `:recovering`.

This scenario now guards the fixed behavior: the slave worker probes its stored
position, reclaims an anonymous fixed station locally when identity matches, and
reruns its own PREOP rebuild before the master resumes OP.

## Expected Behavior

1. Silent PDO failures should still drive the master into `:recovering` even if
   FPRD health polling stays green.
2. Full disconnect should be detected promptly by the default AL health poll.
3. If the slave comes back anonymous at the same configured scan position, the
   slave worker should reclaim its fixed station locally and rebuild to PREOP.
4. The master should then return the session to `:operational`.

## Test Shape

### Test A: silent PDO failure still recovers

1. Boot operational ring with health polling.
2. Inject `logical_wkc_offset` fault (domain sees wkc_mismatch, health
   poll still works — models partial hardware failure).
3. Assert master enters `:recovering` via domain wkc_mismatch.
4. Clear the fault (slave "recovers").
5. Assert master returns to `:operational`.

### Test B: full disconnect → reconnect recovery

1. Boot operational ring with health polling.
2. Inject `Fault.disconnect` for bounded window.
3. Assert master enters `:recovering`.
4. Assert slave transitions away from `:op` (health poll detects it).
5. Wait for fault window to expire (slave reconnects and rebuilds).
6. Assert master returns to `:operational`.
7. Assert loopback I/O works.

### Test C: disconnected slave returns anonymous and reclaims station locally

1. Disconnect the PDO slave long enough for recovery to start.
2. Power-cycle it while still disconnected so it returns at station `0x0000`.
3. Assert the slave reclaims its configured fixed station locally.
4. Assert master still returns to `:operational`.

### Test D: anonymous power-cycle without a disconnect window

1. Power-cycle the PDO slave while it is still physically present.
2. Assert the slave returns anonymous at station `0x0000`.
3. Assert local station reclaim and PREOP rebuild succeed.
4. Assert master returns to `:operational`.
