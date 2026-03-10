EtherCAT State Machine (ESM) lifecycle for one physical slave device.

This module is intentionally the `gen_statem` shell for one physical slave.
Bootstrap, transition walking, mailbox setup, process-data registration, health
polling, and signal delivery live in `EtherCAT.Slave.Runtime.*` helpers so the
main state machine can be inspected directly against the EtherCAT slave-state
model.

One `Slave` process is started per named slave and registered under
`{:slave, name}`. The slave owns INIT → PREOP → SAFEOP → OP transitions,
mailbox configuration, process-data SM/FMMU setup, and DC signal programming.

Typically driven by the master — use `EtherCAT.read_input/2`,
`EtherCAT.write_output/3`, and `EtherCAT.subscribe/3` from the top-level API.
Low-level direct access is available through `EtherCAT.Slave.API`.

## State Transitions

```mermaid
stateDiagram-v2
    state "INIT" as init
    state "BOOTSTRAP" as bootstrap
    state "PREOP" as preop
    state "SAFEOP" as safeop
    state "OP" as op
    state "DOWN" as down
    [*] --> init
    init --> preop: auto-advance succeeds
    init --> init: auto-advance retries
    init --> bootstrap: bootstrap is requested
    init --> safeop: SAFEOP is requested
    init --> op: OP is requested
    bootstrap --> init: INIT is requested
    preop --> safeop: SAFEOP is requested
    preop --> op: OP is requested
    preop --> init: INIT is requested
    safeop --> op: OP is requested
    safeop --> preop: PREOP is requested
    safeop --> init: INIT is requested
    op --> safeop: SAFEOP is requested or AL health retreats
    op --> preop: PREOP is requested
    op --> init: INIT is requested
    op --> down: health poll sees bus loss or zero WKC
    down --> preop: reconnect is authorized and PREOP rebuild succeeds
    down --> init: reconnect retries from INIT
```
