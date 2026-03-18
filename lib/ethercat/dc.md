Distributed Clocks — clock initialization and runtime maintenance.

`EtherCAT.DC` is the public boundary for network-wide Distributed Clocks.
Its internal `EtherCAT.DC.FSM` process owns the runtime `gen_statem`
lifecycle, while one-time clock initialization and runtime tick mechanics live
in internal DC helpers surfaced through the public module.

## State-Machine Boundary

`EtherCAT.DC.FSM` has one actual `gen_statem` state: `:running`. It owns the
DC runtime tick loop and the replies that expose current runtime status.

Initialization, tick mechanics, and status projection live in internal DC
helpers surfaced through `EtherCAT.DC`.

## Initialization

`DC.initialize_clocks/2` performs the one-time clock synchronization
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

The chart below documents `EtherCAT.DC.Status.lock_state`, not a separate
`gen_statem` state machine.

```mermaid
stateDiagram-v2
    state "disabled" as disabled
    state "inactive" as inactive
    state "unavailable" as unavailable
    state "locking" as locking
    state "locked" as locked

    [*] --> disabled: no DC config
    [*] --> inactive: DC configured, runtime not started
    inactive --> unavailable: runtime starts with no monitored stations
    inactive --> locking: runtime starts with monitored stations
    unavailable --> unavailable: FRMW maintenance with no monitorable stations
    locking --> locked: after warmup, sync diff stays within threshold
    locking --> locking: sync diff above threshold or diagnostics fail
    locked --> locking: sync diff rises above threshold or diagnostics fail
    unavailable --> inactive: runtime stops
    locking --> inactive: runtime stops
    locked --> inactive: runtime stops
```
