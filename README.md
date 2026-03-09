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

- The master owns startup, activation, degraded mode, and recovery decisions.
- The bus is the single serialization point for all frames.
- Domains own logical PDO images and cyclic LRW exchange.
- Slaves own AL transitions, SII/mailbox/PDO setup, and signal decode/encode.
- DC owns distributed-clock initialization, lock monitoring, and runtime maintenance.

If you understand those five roles, the rest of the API is predictable.

## Lifecycle

Public startup and runtime health are exposed through `EtherCAT.phase/0`:

- `:idle`
- `:scanning`
- `:configuring`
- `:preop_ready`
- `:operational`
- `:degraded`
- `:recovering`

`await_running/1` waits for a usable session. `await_operational/1` waits for cyclic OP.

### 1. Master-owned lifecycle

This is the actual user-facing `phase/0` model. Activation problems surface as
`:degraded`; runtime path faults surface as `:recovering`.

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> scanning: start/1
    scanning --> configuring: pending slave_ready(:preop)
    scanning --> preop_ready: dynamic PREOP startup
    scanning --> operational: activation succeeds immediately
    scanning --> degraded: activation incomplete
    scanning --> idle: configuration failure / stop
    configuring --> preop_ready: all slaves ready / no activatable slaves
    configuring --> operational: all slaves ready / activation succeeds
    configuring --> degraded: activation incomplete
    configuring --> idle: timeout / activation failure / stop
    preop_ready --> operational: activate/0
    preop_ready --> degraded: activate/0 incomplete
    preop_ready --> idle: stop/0
    degraded --> operational: degraded retry clears activation failures
    degraded --> idle: stop/0 or bus down
    operational --> recovering: domain / slave / DC runtime fault
    operational --> idle: stop/0 or fatal failure
    recovering --> operational: runtime faults cleared
    recovering --> idle: stop/0 or unrecoverable recovery
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
    Master->>Bus: BRD count, station assignment,\nlink verification
    Master->>DC: initialize_clocks(bus, topology)
    Master->>Domain: start_link(:open) for each domain
    Master->>Slave: start_link(...) for each slave
    Slave->>Bus: INIT -> SII -> mailbox SM setup -> PREOP
    Slave->>Domain: register PDO layout while domain is :open
    Slave-->>Master: slave_ready(:preop)
    opt activatable session
        Master->>DC: start runtime maintenance
        Master->>Domain: start_cycling()
        opt await_lock? == true
            Master->>DC: await_locked()
        end
        Master->>Slave: request(:safeop)
        Master->>Slave: request(:op)
    end
    Master-->>App: phase = :preop_ready or :operational
```

### 3. Runtime fault recovery

This library aims for BEAM-friendly fault tolerance: keep healthy work running when
possible, surface faults explicitly, and let the master own recovery policy.

```mermaid
sequenceDiagram
    autonumber
    participant Domain
    participant Slave
    participant DC
    participant Master
    participant Bus

    Domain-->>Master: domain_cycle_invalid / domain_stopped
    Slave-->>Master: slave_down / slave_retreated
    DC-->>Master: dc_runtime_failed / dc_lock_lost
    Master-->>App: phase = :recovering
    opt cyclic path still valid
        Note over Domain,Master: healthy domains may keep cycling
    end
    opt stopped domain
        Master->>Domain: start_cycling(domain_id)
    end
    opt reconnected slave
        Slave-->>Master: slave_reconnected
        Master->>Slave: authorize_reconnect()
        Slave->>Bus: INIT -> SII -> mailbox SM setup -> PREOP
        Slave-->>Master: slave_ready(:preop)
        Master->>Slave: request(:op)
    end
    DC-->>Master: dc_runtime_recovered / dc_lock_regained
    Master-->>App: phase = :operational
```

### 4. Runtime state charts by process

These charts reflect the current code paths and their protocol areas:

- `Master` / `Domain`: startup, activation, cyclic runtime, and recovery
- `Slave`: ESM transitions, AL control, and slave-local configuration
- `DC`: distributed-clock initialization and runtime lock tracking

#### Master (`lib/ethercat/master.ex`)

`Master` has real `gen_statem` states plus a split public phase inside `:running`.

```mermaid
stateDiagram-v2
    state ":running / activation_phase=:preop_ready" as running_preop
    state ":running / activation_phase=:operational" as running_op
    [*] --> idle
    idle --> scanning: start/1
    scanning --> configuring: configure_network / pending_preop > 0
    scanning --> running_preop: activation_phase = :preop_ready
    scanning --> running_op: activation_phase = :operational
    scanning --> degraded: activation incomplete
    scanning --> idle: configuration failure / stop / bus down
    configuring --> running_preop: all slave_ready(:preop) / dynamic PREOP startup
    configuring --> running_op: all slave_ready(:preop) / activation succeeds
    configuring --> degraded: activation incomplete
    configuring --> idle: timeout / activation failure / stop / bus down
    running_preop --> running_op: activate/0
    running_preop --> degraded: activate/0 incomplete
    running_preop --> idle: stop / bus down
    running_op --> recovering: domain / slave / DC runtime fault
    running_op --> idle: stop / bus down / fatal DC policy
    degraded --> running_op: degraded retry clears activation failures
    degraded --> idle: stop / bus down
    recovering --> running_op: runtime_faults cleared
    recovering --> idle: stop / unrecoverable recovery / bus down
```

#### Slave (`lib/ethercat/slave.ex`)

This chart shows the `Slave` process states. `request/2` can walk multiple AL
steps on the wire before the shell lands in the final target state.

```mermaid
stateDiagram-v2
    [*] --> init
    init --> preop: auto_advance / initialize_to_preop succeeds
    init --> init: auto_advance retry
    init --> bootstrap: request(:bootstrap)
    init --> safeop: request(:safeop)
    init --> op: request(:op)
    bootstrap --> init: request(:init)
    preop --> safeop: request(:safeop)
    preop --> op: request(:op)
    preop --> init: request(:init)
    safeop --> op: request(:op)
    safeop --> preop: request(:preop)
    safeop --> init: request(:init)
    op --> safeop: request(:safeop) or AL health retreat
    op --> preop: request(:preop)
    op --> init: request(:init)
    op --> down: health poll bus loss / wkc = 0
    down --> preop: authorize_reconnect / INIT→PREOP succeeds
    down --> init: authorize_reconnect / retry path
```

#### Domain (`lib/ethercat/domain.ex`)

`Domain` has three process states. Inside `:cycling`, `cycle_health` tracks
whether the current continuous loop is healthy or invalid.

```mermaid
stateDiagram-v2
    [*] --> open
    open --> cycling: start_cycling / Layout.prepare succeeds
    cycling --> stopped: stop_cycling / miss_threshold reached
    stopped --> cycling: start_cycling

    state cycling {
        [*] --> healthy
        healthy --> invalid: WKC mismatch or transport miss
        invalid --> healthy: next valid LRW cycle
    }
```

#### DC (`lib/ethercat/dc.ex`)

`DC` keeps one runtime process state, `:running`. The meaningful transitions are
its internal `lock_state`.

```mermaid
stateDiagram-v2
    state ":running / lock_state=:unavailable" as running_unavailable
    state ":running / lock_state=:locking" as running_locking
    state ":running / lock_state=:locked" as running_locked
    [*] --> running_unavailable: no monitored stations
    [*] --> running_locking: monitored stations present
    running_locking --> running_locked: sync diff <= threshold after warmup
    running_locked --> running_locking: sync diff > threshold
    running_locked --> running_locking: diagnostic failure
    running_locking --> running_locking: FRMW tick / warmup / retry
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
