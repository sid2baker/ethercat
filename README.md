# EtherCAT

Pure-Elixir EtherCAT master built on OTP.

This library talks EtherCAT over a standard Ethernet interface. It does not need
an RTOS, a kernel patch, or a proprietary NIC driver.

## EtherCAT In One Minute

EtherCAT is an industrial Ethernet fieldbus.

Unlike a normal request/response protocol, the master sends one Ethernet frame
through the whole slave chain. Each slave reads and writes its own bytes in
hardware while that frame passes through. When the frame comes back, the master
has exchanged the whole process image in one network round-trip.

That gives you:

- deterministic cyclic I/O
- hardware-enforced input/output mapping via SyncManagers and FMMUs
- mailbox protocols such as CoE / SDO for configuration
- optional Distributed Clocks for sub-microsecond clock alignment across slaves

## What This Library Is Good At

Good fit:

- discrete I/O
- Beckhoff terminal stacks
- configuration and diagnostics tooling
- 1 ms to 10 ms cyclic control loops
- applications that benefit from BEAM supervision and fault isolation

Not the right fit:

- sub-millisecond hard real-time control loops
- applications that require the master process itself to meet microsecond deadlines

## Before You Start

You need:

- a dedicated Ethernet interface connected to an EtherCAT ring
- `CAP_NET_RAW` or root privileges for raw socket access
- real hardware; most of the useful validation in this repo is hardware-first

Current runtime constraints:

- `Domain.Config.cycle_time_us` must be a whole-millisecond value
- `DC.Config.cycle_ns` must be a whole-millisecond value
- practical minimum cycle time is currently `1 ms`

Grant raw socket capability without running as root:

```bash
sudo setcap cap_net_raw+ep _build/dev/lib/ethercat/priv/raw_socket
```

## First Successful Run: Discover Your Bus

If you just want to confirm that the library can see your EtherCAT ring, start
without any slave or domain configuration.

```elixir
:ok =
  EtherCAT.start(
    interface: "eth0"
  )

:ok = EtherCAT.await_running(10_000)

%{
  phase: EtherCAT.phase(),
  state: EtherCAT.state(),
  slaves: EtherCAT.slaves(),
  last_failure: EtherCAT.last_failure()
}
```

What this does:

- opens the bus
- discovers the ring
- assigns station addresses starting at `0x1000`
- starts one default slave process per discovered station
- holds them in `:preop` so you can inspect the network safely

Expected result:

- `phase: :preop_ready`
- `slaves: [{name, station, pid}, ...]`
- `last_failure: nil`

`PREOP` is EtherCAT's configuration state: mailbox traffic works, but cyclic
process-data exchange is not running yet.

Stop the session when done:

```elixir
:ok = EtherCAT.stop()
```

## Next Step: Exchange Process Data

To exchange cyclic PDOs, you need:

1. a `Domain` (the master's cyclic process image)
2. one `Slave.Config` per named slave you care about
3. a driver module that describes the slave's process-data model

Minimal shape:

```elixir
defmodule MyApp.EL1809Driver do
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_model(_config), do: %{input_0: 0x1A00}

  @impl true
  def encode_signal(:input_0, _config, _value), do: <<>>

  @impl true
  def decode_signal(:input_0, _config, <<_::7, bit::1>>), do: bit
  def decode_signal(:input_0, _config, _raw), do: 0
end

defmodule MyApp.EL2809Driver do
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_model(_config), do: %{output_0: 0x1600}

  @impl true
  def encode_signal(:output_0, _config, value), do: <<value::8>>

  @impl true
  def decode_signal(:output_0, _config, _raw), do: nil
end
```

```elixir
:ok =
  EtherCAT.start(
    interface: "eth0",
    dc: %EtherCAT.DC.Config{cycle_ns: 1_000_000},
    domains: [
      %EtherCAT.Domain.Config{id: :io, cycle_time_us: 1_000, miss_threshold: 500}
    ],
    slaves: [
      %EtherCAT.Slave.Config{name: :coupler},
      %EtherCAT.Slave.Config{
        name: :inputs,
        driver: MyApp.EL1809Driver,
        process_data: {:all, :io}
      },
      %EtherCAT.Slave.Config{
        name: :outputs,
        driver: MyApp.EL2809Driver,
        process_data: {:all, :io}
      }
    ]
  )

:ok = EtherCAT.await_operational(10_000)
```

Then use the runtime API:

```elixir
EtherCAT.subscribe(:inputs, :input_0, self())

{:ok, bit} = EtherCAT.read_input(:inputs, :input_0)
:ok = EtherCAT.write_output(:outputs, :output_0, 1)
```

Important: `write_output/3` stages the next value into the master's domain
buffer. It confirms the staged bytes, not immediate physical pin state.

## If You Have The Repo's Beckhoff Loopback Ring

This repository is developed against a small Beckhoff ring:

```text
EK1100 coupler
EL1809 16-ch digital input
EL2809 16-ch digital output
EL3202 2-ch RTD input
```

Each EL2809 output is wired to the matching EL1809 input.

Start with these maintained harnesses:

- `examples/livebooks/hardware_validation_livebook.livemd`
  Interactive bring-up, manual I/O checks, latency tests, priority stress, DC status.
- `examples/livebooks/el1809_el2809_benchmarks.livemd`
  Focused EL1809/EL2809 loopback measurements.
- `examples/README.md`
  Maintainer-oriented scripts and diagnostics.

Use a Mix runtime when opening the Livebooks.

## Public API Overview

Top-level entrypoints in `EtherCAT`:

- `start/1`, `stop/0`
- `await_running/1`, `await_operational/1`
- `phase/0`, `state/0`, `last_failure/0`
- `slaves/0`
- `read_input/2`, `write_output/3`, `subscribe/3`
- `dc_status/0`, `reference_clock/0`, `await_dc_locked/1`
- `configure_slave/2`, `activate/0` for dynamic PREOP workflows
- `download_sdo/4`, `upload_sdo/3` for CoE mailbox access

Advanced raw frame access:

```elixir
alias EtherCAT.Bus.Transaction

bus = EtherCAT.bus()

{:ok, result} =
  EtherCAT.Bus.transaction(
    bus,
    Transaction.new()
    |> Transaction.fprd(station_addr, register, 2)
    |> Transaction.fpwr(station_addr, register, data)
  )
```

## Why Elixir Can Work Here

The hard timing point in EtherCAT is usually not “when the BEAM thread woke up.”
It is “when the slave hardware sampled or applied data.”

With Distributed Clocks enabled, that timing anchor lives in the slaves' own DC
hardware clocks and SYNC pulses. The master's job is to deliver fresh frames
inside the cycle window. That is why a pure-Elixir master can be viable for
whole-millisecond workloads even though it is not a hard real-time runtime.

## Architecture

High-level shape:

```text
EtherCAT.Master   - session lifecycle and activation
EtherCAT.Bus      - frame scheduling and wire I/O
EtherCAT.Domain   - cyclic LRW process-image exchange
EtherCAT.Slave    - per-slave ESM lifecycle and configuration
EtherCAT.DC       - distributed-clock maintenance and lock monitoring
```

For the full map, read [ARCHITECTURE.md](ARCHITECTURE.md).

## Documentation Map

Start here if you need more depth:

- `docs/index.md`
- `ARCHITECTURE.md`
- `lib/ethercat/master.md`
- `lib/ethercat/slave.md`
- `lib/ethercat/domain.md`
- `docs/references/README.md`

Contributor tooling:

- `mix ethercat.harness.doctor`
- `mix test`

## Installation

```elixir
def deps do
  [{:ethercat, "~> 0.1.0"}]
end
```

Docs: `mix docs` or https://hexdocs.pm/ethercat
