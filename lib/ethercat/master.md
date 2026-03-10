Master orchestrates startup, activation, and runtime recovery for the EtherCAT session.

This module is intentionally the `gen_statem` shell for the master lifecycle.
Protocol-heavy work lives in `EtherCAT.Master.*` helpers so the state machine
can be reviewed against the EtherCAT startup and continuous-loop model without
also wading through all implementation details inline.

The master owns the public lifecycle exposed via `EtherCAT.state/0`. Each state
maps 1:1 to an actual `EtherCAT.Master` `gen_statem` state.

## Lifecycle States

- `:idle` - No session active
- `:discovering` - Scanning the bus, counting slaves, assigning stations, and preparing startup
- `:awaiting_preop` - Waiting for configured slaves to reach PREOP
- `:preop_ready` - All slaves in PREOP, ready for activation or dynamic configuration
- `:operational` - Cyclic operation active; non-critical per-slave faults are tracked separately
- `:activation_blocked` - Activation incomplete (DC lock, slave failures, etc.)
- `:recovering` - Runtime fault detected and the master is healing critical runtime faults

## Startup Sequencing

```mermaid
sequenceDiagram
    autonumber
    participant App
    participant Master
    participant Bus
    participant DC
    participant Domain
    participant Slave

    App->>Master: start/1
    Master->>Bus: count slaves, assign stations,\\nverify link
    opt DC is configured
        Master->>DC: initialize clocks
    end
    Master->>Domain: start domains in open state
    Master->>Slave: start slave processes
    Slave->>Bus: reach PREOP through INIT,\\nSII, and mailbox setup
    Slave->>Domain: register PDO layout
    Slave-->>Master: report ready at PREOP
    opt activation is requested and possible
        opt DC runtime is available
            Master->>DC: start runtime maintenance
        end
        Master->>Domain: start cyclic exchange
        opt DC lock is required
            Master->>DC: wait for lock
        end
        Master->>Slave: request SAFEOP
        Master->>Slave: request OP
    end
    Master-->>App: state becomes preop_ready or operational
```

## Runtime Fault Recovery

```mermaid
sequenceDiagram
    autonumber
    participant App
    participant Domain
    participant Slave
    participant DC
    participant Master
    participant Bus

    Domain-->>Master: cycle is invalid or domain stops
    Slave-->>Master: slave goes down, retreats, or reconnects
    DC-->>Master: runtime fails or lock is lost
    opt a domain or DC fault is critical
        Master-->>App: state becomes recovering
    end
    opt unaffected domains remain valid
        Note over Domain,Master: healthy domains may keep cycling
    end
    opt a domain stopped
        Master->>Domain: restart the affected cycle
    end
    opt a slave reconnects
        Slave-->>Master: slave reconnects
        Master->>Slave: authorize reconnect
        Slave->>Bus: rebuild to PREOP through INIT,\\nSII, and mailbox setup
        Slave-->>Master: report ready at PREOP
        Master->>Slave: request OP
    end
    opt a DC fault is part of the runtime fault set
        DC-->>Master: runtime recovers or lock returns
    end
    Master-->>App: state becomes operational
```

## State Transitions

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> discovering: start/1
    discovering --> awaiting_preop: configured slaves are still pending
    discovering --> preop_ready: startup completes without activation
    discovering --> operational: startup completes and activation succeeds
    discovering --> activation_blocked: startup completes but activation is incomplete
    discovering --> idle: configuration fails, stop, or bus down
    awaiting_preop --> preop_ready: all slaves reached PREOP, no activation requested
    awaiting_preop --> operational: all slaves reached PREOP and activation succeeds
    awaiting_preop --> activation_blocked: all slaves reached PREOP but activation is incomplete
    awaiting_preop --> idle: timeout, activation failure, stop, or bus down
    preop_ready --> operational: activate/0 succeeds
    preop_ready --> activation_blocked: activate/0 is incomplete
    preop_ready --> idle: stop or bus down
    operational --> recovering: runtime fault in domain or DC
    operational --> idle: stop, bus down, or fatal DC policy
    activation_blocked --> operational: activation failures clear and no runtime faults remain
    activation_blocked --> recovering: activation failures clear but runtime faults remain
    activation_blocked --> idle: stop or bus down
    recovering --> operational: runtime faults are cleared
    recovering --> idle: stop, bus down, or recovery fails
```
