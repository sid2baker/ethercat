# EtherCAT

[![Hex version](https://img.shields.io/hexpm/v/ethercat.svg)](https://hex.pm/packages/ethercat)
[![Hexdocs](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/ethercat)
[![License](https://img.shields.io/hexpm/l/ethercat)](https://github.com/sid2baker/ethercat/blob/main/LICENSE)

[![EtherCAT demo](https://img.youtube.com/vi/huwbTsmTPHc/maxresdefault.jpg)](https://www.youtube.com/watch?v=huwbTsmTPHc)

Pure-Elixir EtherCAT master built on OTP.

- No NIF.
- No kernel module.
- Nerves-first, runs on standard Linux too.
- Best for discrete I/O, Beckhoff terminal stacks, diagnostics, and 1 ms to 10 ms cyclic loops.
- Not the right fit for sub-millisecond hard real-time control.

The entry idea is simple: the **master owns the session lifecycle**, **domains own cyclic LRW exchange**, **slaves own ESM and slave-local configuration**, and **DC owns clock discipline**. When runtime faults happen, the public phase moves to `:recovering`, healthy parts keep running when possible, and the master decides how to recover.

## Installation

```elixir
def deps do
  [{:ethercat, "~> 0.1.0"}]
end
```

Raw Ethernet socket access requires `CAP_NET_RAW` or root:

```bash
sudo setcap cap_net_raw+ep _build/dev/lib/ethercat/priv/raw_socket
```

## Quick Start

### Discover a ring

```elixir
EtherCAT.start(interface: "eth0")

:ok = EtherCAT.await_running()

EtherCAT.phase()
#=> :preop_ready

EtherCAT.slaves()
#=> [
#=>   %{name: :slave_0, station: 0x1000, server: {:via, Registry, ...}, pid: #PID<...>},
#=>   ...
#=> ]

EtherCAT.stop()
```

If you start without explicit slave configs, EtherCAT still scans the ring, names each
station, and brings every slave to `:preop`. That is the right entry point for
exploration, diagnostics, and dynamic configuration.

### Run cyclic PDO I/O

```elixir
defmodule MyApp.EL1809 do
  @behaviour EtherCAT.Slave.Driver

  def process_data_model(_), do: [ch1: 0x1A00]
  def encode_signal(_, _, _), do: <<>>
  def decode_signal(_, _, <<_::7, bit::1>>), do: bit
  def decode_signal(_, _, _), do: 0
end

EtherCAT.start(
  interface: "eth0",
  domains: [%EtherCAT.Domain.Config{id: :io, cycle_time_us: 1_000}],
  slaves: [
    %EtherCAT.Slave.Config{name: :coupler},
    %EtherCAT.Slave.Config{
      name: :inputs,
      driver: MyApp.EL1809,
      process_data: {:all, :io},
      target_state: :op
    }
  ]
)

:ok = EtherCAT.await_operational()

EtherCAT.subscribe(:inputs, :ch1)
{:ok, %{value: bit, updated_at_us: updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
```

For PREOP-first workflows, configure discovered slaves dynamically:

```elixir
EtherCAT.start(
  interface: "eth0",
  domains: [%EtherCAT.Domain.Config{id: :main, cycle_time_us: 1_000}]
)

:ok = EtherCAT.await_running()

:ok =
  EtherCAT.configure_slave(
    :slave_1,
    driver: MyApp.EL1809,
    process_data: {:all, :main},
    target_state: :op
  )

:ok = EtherCAT.activate()
:ok = EtherCAT.await_operational()
```

## Mental Model

- The master owns startup, activation-blocked startup, and runtime recovery decisions.
- The bus is the single serialization point for all frames.
- Domains own logical PDO images and cyclic LRW exchange.
- Slaves own AL transitions, SII/mailbox/PDO setup, and signal decode/encode.
- DC owns distributed-clock initialization, lock monitoring, and runtime maintenance.

If you understand those five roles, the rest of the API is predictable.

## Lifecycle

Public startup and runtime health are exposed through `EtherCAT.phase/0`:

- `:idle`
- `:discovering`
- `:awaiting_preop`
- `:preop_ready`
- `:operational`
- `:activation_blocked`
- `:recovering`

`await_running/1` waits for a usable session. `await_operational/1` waits for cyclic OP.

### 1. Master-owned lifecycle

This is the actual user-facing `phase/0` model. Activation problems surface as
`:activation_blocked`; runtime path faults surface as `:recovering`.

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> discovering: start/1
    discovering --> awaiting_preop: configured slaves are still pending
    discovering --> preop_ready: startup completes without activation
    discovering --> operational: startup completes and activation succeeds
    discovering --> activation_blocked: startup completes but activation is incomplete
    discovering --> idle: configuration fails or stop/0
    awaiting_preop --> preop_ready: all slaves reached PREOP, no activation requested
    awaiting_preop --> operational: all slaves reached PREOP and activation succeeds
    awaiting_preop --> activation_blocked: all slaves reached PREOP but activation is incomplete
    awaiting_preop --> idle: timeout, activation failure, or stop/0
    preop_ready --> operational: activate/0 succeeds
    preop_ready --> activation_blocked: activate/0 is incomplete
    preop_ready --> idle: stop/0
    activation_blocked --> operational: retry clears activation failures and no runtime faults remain
    activation_blocked --> recovering: activation failures clear but runtime faults remain
    activation_blocked --> idle: stop/0 or bus down
    operational --> recovering: runtime fault in domain, slave, or DC
    operational --> idle: stop/0 or fatal failure
    recovering --> operational: runtime faults are cleared
    recovering --> idle: stop/0 or recovery fails
```

### 2. Startup sequencing across subsystems

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
    Master->>Bus: count slaves, assign stations,\nverify link
    opt DC is configured
        Master->>DC: initialize clocks
    end
    Master->>Domain: start domains in open state
    Master->>Slave: start slave processes
    Slave->>Bus: reach PREOP through INIT,\nSII, and mailbox setup
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
    Master-->>App: phase becomes preop_ready or operational
```

### 3. Runtime fault recovery

This library aims for BEAM-friendly fault tolerance: keep healthy work running when
possible, surface faults explicitly, and let the master own recovery policy.

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
    Slave-->>Master: slave goes down or retreats
    DC-->>Master: runtime fails or lock is lost
    Master-->>App: phase becomes recovering
    opt unaffected domains remain valid
        Note over Domain,Master: healthy domains may keep cycling
    end
    opt a domain stopped
        Master->>Domain: restart the affected cycle
    end
    opt a slave reconnects
        Slave-->>Master: slave reconnects
        Master->>Slave: authorize reconnect
        Slave->>Bus: rebuild to PREOP through INIT,\nSII, and mailbox setup
        Slave-->>Master: report ready at PREOP
        Master->>Slave: request OP
    end
    opt a DC fault is part of the runtime fault set
        DC-->>Master: runtime recovers or lock returns
    end
    Master-->>App: phase becomes operational
```

### 4. Runtime state charts by process

These charts reflect the current code paths and their protocol areas:

If you only need the public contract, the master-owned lifecycle above is the
one to read first. The charts below are implementation-facing.

- `Master` / `Domain`: startup, activation, cyclic runtime, and recovery
- `Slave`: ESM transitions, AL control, and slave-local configuration
- `DC`: distributed-clock initialization and runtime lock tracking

#### Master (`lib/ethercat/master.ex`)

`Master` uses real tuple-based running states, `{:running, :preop_ready}` and
`{:running, :operational}`, plus a public `phase/0` projection. This chart now
maps the implementation 1:1: every node is an actual `Master` state, and the
running tuple states are shown directly instead of through helper nodes.

```mermaid
stateDiagram-v2
    state "{:running, :preop_ready}" as running_preop
    state "{:running, :operational}" as running_operational

    [*] --> idle
    idle --> discovering: start/1
    discovering --> awaiting_preop: configured slaves are still pending
    discovering --> running_preop: startup completes without activation
    discovering --> running_operational: startup completes and activation succeeds
    discovering --> activation_blocked: startup completes but activation is incomplete
    discovering --> idle: configuration fails, stop, or bus down
    awaiting_preop --> running_preop: all slaves reached PREOP, no activation requested
    awaiting_preop --> running_operational: all slaves reached PREOP and activation succeeds
    awaiting_preop --> activation_blocked: all slaves reached PREOP but activation is incomplete
    awaiting_preop --> idle: timeout, activation failure, stop, or bus down
    running_preop --> running_operational: activate/0 succeeds
    running_preop --> activation_blocked: activate/0 is incomplete
    running_preop --> idle: stop or bus down
    running_operational --> recovering: runtime fault in domain, slave, or DC
    running_operational --> idle: stop, bus down, or fatal DC policy
    activation_blocked --> running_operational: activation failures clear and no runtime faults remain
    activation_blocked --> recovering: activation failures clear but runtime faults remain
    activation_blocked --> idle: stop or bus down
    recovering --> running_operational: runtime faults are cleared
    recovering --> idle: stop, bus down, or recovery fails
```

#### Slave (`lib/ethercat/slave.ex`)

This chart shows the `Slave` process states. `request/2` can walk multiple AL
steps on the wire before the shell lands in the final target state.

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

#### Domain (`lib/ethercat/domain.ex`)

`Domain` has three process states. Inside `:cycling`, `cycle_health` tracks
whether the current continuous loop is healthy or invalid.

```mermaid
stateDiagram-v2
    [*] --> open
    open --> cycling: start_cycling and layout preparation succeed
    cycling --> stopped: stop_cycling or miss threshold is reached
    stopped --> cycling: start_cycling

    state cycling {
        [*] --> healthy
        healthy --> invalid: WKC mismatch or transport miss
        invalid --> healthy: next LRW cycle is valid
    }
```

#### DC (`lib/ethercat/dc.ex`)

`DC` keeps one runtime process state, `:running`. The meaningful transitions are
its internal `lock_state`.

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

## Failure Model

- A slave disconnect does not automatically mean full-session teardown.
- Invalid WKC or slave health loss moves the master to `:recovering`.
- Healthy domains can keep cycling if the fault is localized and the transport is still usable.
- Total bus loss can stop domains after the configured miss threshold; recovery can restart them.
- Slave reconnect is PREOP-first: the slave rebuilds its local state, then the master decides when to return it to OP.

The maintained end-to-end hardware walkthrough for this is:

- [`examples/fault_tolerance.exs`](examples/fault_tolerance.exs)

## Where To Start

### Fastest path

[`kino_ethercat`](https://github.com/sid2baker/kino_ethercat) gives you an
interactive UI for ring discovery, I/O control, and diagnostics.

### Maintained hardware examples

See [`examples/README.md`](examples/README.md) for the maintained hardware scripts.
Recommended first stops:

- `examples/scan.exs`
- `examples/diag.exs`
- `examples/wiring_map.exs`
- `examples/dc_sync.exs`
- `examples/fault_tolerance.exs`

### Deeper architecture

- [`ARCHITECTURE.md`](https://github.com/sid2baker/ethercat/blob/main/ARCHITECTURE.md) for subsystem boundaries and data flow
- [`hexdocs.pm/ethercat`](https://hexdocs.pm/ethercat) for the API reference

## Mapping Rules

- High-level `%EtherCAT.Domain.Config{}` periods currently use a whole-millisecond scheduling contract with a minimum of `1_000 us`.
- High-level `EtherCAT.start/1` domain configs do not take `logical_base`; the master allocates logical windows automatically.
