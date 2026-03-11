Master orchestrates startup, activation, and runtime recovery for the EtherCAT session.

This module is intentionally the `gen_statem` state-machine module for the
master lifecycle.
Protocol-heavy work lives in `EtherCAT.Master.*` helpers so the state machine
can be reviewed against the EtherCAT startup and continuous-loop model without
also wading through all implementation details inline.

The master owns the public lifecycle exposed via `EtherCAT.state/0`. Each state
maps 1:1 to an actual `EtherCAT.Master` `gen_statem` state.

## State-Machine Boundary

`EtherCAT.Master` should mention domains, slaves, and DC as session concepts:
their events, tracked refs, and the policy that decides the next master state.

It should not perform low-level subsystem mechanics inline. Calls like
requesting slave transitions, authorizing reconnects, starting/stopping
domains, or querying DC runtime status belong in `EtherCAT.Master.*` helpers
such as `Activation`, `Recovery`, `Status`, `Calls`, and `Startup`.

That split is deliberate: the state-machine module stays readable as a session
state machine, while the helpers own the operational detail.

## Lifecycle States

- `:idle` - No session active
- `:discovering` - Scanning the bus, counting slaves, assigning stations, and preparing startup
- `:awaiting_preop` - Waiting for configured slaves to reach PREOP
- `:preop_ready` - All slaves in PREOP, ready for activation or dynamic configuration
- `:deactivated` - Session stays live but the desired runtime target is intentionally below OP
- `:operational` - Cyclic operation active; non-critical per-slave faults are tracked separately
- `:activation_blocked` - Transition to the desired runtime target is incomplete
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
    Master-->>App: state becomes preop_ready, activation_blocked, or operational
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
    opt a critical runtime fault is present
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
    discovering --> idle: startup fails or stop/0
    awaiting_preop --> preop_ready: all slaves reached PREOP, no activation requested
    awaiting_preop --> operational: all slaves reached PREOP and activation succeeds
    awaiting_preop --> activation_blocked: all slaves reached PREOP but activation is incomplete
    awaiting_preop --> idle: timeout, fatal activation failure, or stop/0
    preop_ready --> operational: activate/0 succeeds
    preop_ready --> deactivated: deactivate/0 settles in SAFEOP
    preop_ready --> activation_blocked: activate/0 is incomplete
    preop_ready --> recovering: critical runtime fault
    preop_ready --> idle: stop/0 or fatal subsystem exit
    deactivated --> operational: activate/0 succeeds
    deactivated --> preop_ready: deactivate(:preop)
    deactivated --> activation_blocked: target transition remains incomplete
    deactivated --> recovering: runtime fault in retained session structure
    deactivated --> idle: stop/0 or fatal subsystem exit
    operational --> recovering: runtime fault in domain or DC
    operational --> deactivated: deactivate/0 settles in SAFEOP
    operational --> preop_ready: deactivate(:preop)
    operational --> idle: stop/0 or fatal subsystem exit
    activation_blocked --> operational: activation failures clear and target is OP
    activation_blocked --> deactivated: transition failures clear and target is SAFEOP
    activation_blocked --> preop_ready: transition failures clear and target is PREOP
    activation_blocked --> recovering: activation failures clear but runtime faults remain
    activation_blocked --> idle: stop/0 or fatal subsystem exit
    recovering --> operational: critical runtime faults are cleared and target is OP
    recovering --> deactivated: critical runtime faults are cleared and target is SAFEOP
    recovering --> preop_ready: critical runtime faults are cleared and target is PREOP
    recovering --> idle: stop/0 or recovery fails
```

Physical link loss normally moves the master into `:recovering` through
domain/DC runtime faults. A direct transition to `:idle` is reserved for
explicit stop, startup failure, bus-process exit, or fatal policy.
