## Scenario

Master gets stuck in `:recovering` after a disconnected PDO slave
reconnects. A related limitation is that `slave_info/1` can still report
`al_state: :op` during a silent PDO-only failure because the slave health
poll is register-based, not PDO-based.

## Real-World Analog

On CM4 hardware, a slave loses power or cable temporarily.

**Eventually (after domain cycle detects fault):**
- Master enters `:recovering`
- Slave reconnects (ESC resets to `:init`)
- Domain LRW still gets wkc_mismatch (slave not configured for PDO)
- Nobody reconfigures the slave → master stays in `:recovering` forever

## Root Cause Analysis

Two distinct problems:

### Problem 1: Silent disconnect (no immediate detection)

Without health polling, or when health poll FPRD still succeeds (slave
ESC responds but PDO processing is broken), the slave process has no way
to know it's disconnected. The domain cycle detects it via wkc_mismatch,
but the slave process can stay in `:op`.

This is modeled by `Fault.logical_wkc_offset` — only affects LRW (domain
cycles) but not FPRD (health polls).

### Problem 2: Stuck recovery after reconnect

When the slave physically reconnects after a power cycle, its ESC is at
`:init`. The domain LRW still gets wkc_mismatch because the slave isn't
configured for PDO. But nobody tells the slave process to reconfigure —
it thinks it's still in `:op`.

The master has a `{:domain, :main}` runtime fault that never clears
because the domain wkc never recovers. And no slave fault exists to
trigger the reconnect flow.

## Expected Behavior

1. Full disconnect should be detected promptly by the default AL health poll.
2. Silent PDO failures should still drive the master into `:recovering`.
3. After reconnect, master should reconfigure the slave and return to
   `:operational`.

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
5. Wait for fault window to expire (slave reconnects).
6. Assert master returns to `:operational`.
7. Assert loopback I/O works.

### Test C: wkc fault during reconnection window

1. Same as Test B, but inject a brief wkc fault after reconnect.
2. Assert master still returns to `:operational`.
