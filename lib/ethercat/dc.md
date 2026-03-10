Distributed Clocks — clock initialization and runtime maintenance.

`EtherCAT.DC` is intentionally the runtime `gen_statem` shell for network-wide
Distributed Clocks maintenance. One-time clock initialization, public API
wrappers, and runtime tick mechanics live in `EtherCAT.DC.*` helpers so the
main module can be inspected as the DC runtime state machine.

## Initialization

`DC.API.initialize_clocks/2` performs the one-time clock synchronization
sequence described in ETG.1000 §9.1.3.6:

1. Trigger receive-time latch on all slaves (BWR to `0x0900`).
2. Read one DC snapshot per slave:
   - DL-status-derived active ports
   - receive time port 0..3
   - ECAT receive time
   - speed counter start
3. Identify the reference clock (first DC-capable slave in bus order).
4. Build a deterministic init plan:
   - chain-only propagation delay estimate from latched receive spans
   - per-slave system time offset against the EtherCAT epoch
   - PLL filter reset value
5. Apply offset + delay writes to every DC-capable slave.
6. Reset PLL filters by writing back the latched speed-counter seed.

The planning step is pure and covered by unit tests. The current topology model
is intentionally explicit: it supports a linear bus ordered by scan position.
More complex tree-delay propagation needs a richer topology graph than the
current master passes into DC init.

## Runtime maintenance

`EtherCAT.DC` is the runtime owner for network-wide Distributed Clocks state.
It sends its own realtime frame at the configured DC cycle:

- every tick: configured-address FRMW to the reference clock system time
  register (`0x0910`)
- every N ticks: append configured-address reads of `0x092C` on the monitored
  DC-capable slaves

That keeps DC ownership out of `Domain`. Domains stay process-image/LRW loops;
`DC` owns clock maintenance, lock classification, diagnostics, and waiters.

## Lock State Transitions

```mermaid
stateDiagram-v2
    state "running / lock unavailable" as running_unavailable
    state "running / locking" as running_locking
    state "running / locked" as running_locked
    [*] --> running_unavailable: no monitored stations
    [*] --> running_locking: monitored stations are present
    running_locking --> running_locked: after warmup, sync diff stays within threshold
    running_locked --> running_locking: sync diff rises above threshold
    running_locked --> running_locking: diagnostics fail
    running_locking --> running_locking: FRMW tick, warmup, or retry
    running_unavailable --> running_unavailable: FRMW maintenance only
```
