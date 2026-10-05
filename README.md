# EtherCAT

[![Hex version](https://img.shields.io/hexpm/v/ethercat.svg)](https://hex.pm/packages/ethercat)
[![Hexdocs](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/ethercat)
[![License](https://img.shields.io/hexpm/l/ethercat)](https://github.com/sid2baker/ethercat/blob/main/LICENSE)

Pure-Elixir EtherCAT master for Linux and Nerves, built on OTP without NIFs or
kernel modules. Intended for discrete I/O, diagnostics, and soft-real-time
1–10 ms cyclic loops—not sub-millisecond hard-real-time control.

> **Experimental; not production-ready.** This project explores soft-real-time
> automation. I would like to develop it into a bachelor's thesis; if you know
> a professor who could help, please reach out.

Want an interactive UI? Start with
[`kino_ethercat`](https://github.com/sid2baker/kino_ethercat).
Without hardware, try the [UDP simulator walkthrough](https://hexdocs.pm/ethercat/0.5.0/EtherCAT.Simulator.html#module-run-a-local-udp-example)
or run the simulator tests below.

## 1. Install and supervise the runtime

This guide targets **EtherCAT 0.5.0**. Add the Hex dependency to your
application's `mix.exs`:

```elixir
def deps do
  [{:ethercat, "~> 0.5.0"}]
end
```

Use the [0.5.0 API reference](https://hexdocs.pm/ethercat/0.5.0/).
Upgrading from `0.4.x`? Read the [migration notes](#upgrade-guide) below;
`0.5.0` changes the runtime and driver APIs without compatibility shims.

Run `mix deps.get`, then add `{EtherCAT.Runtime, []}` to your application's
supervision tree. EtherCAT does not start the runtime automatically.
For a standalone `iex -S mix` session, start it once with:

```elixir
{:ok, _supervisor} =
  Supervisor.start_link([{EtherCAT.Runtime, []}], strategy: :one_for_one)
```

## 2. Discover your hardware

Use a dedicated Ethernet interface connected to your EtherCAT ring. Raw socket
access needs root or `CAP_NET_RAW`. To grant the capability to your current BEAM
executable (this affects every application using that executable):

```bash
BEAM=$(readlink -f "$(dirname "$(dirname "$(command -v erl)")")"/erts-*/bin/beam.smp)
sudo setcap cap_net_raw+ep "$BEAM"
```

Restart IEx/the application after granting the capability. Replace `eth0` with
your interface. Scan **before** opening a master session; scanning assigns
station addresses and must not run against an active ring.

```elixir
backend = {:raw, %{interface: "eth0"}}
{:ok, scan} = EtherCAT.Scan.scan(backend)
scan.discovered_slaves
```

To inspect slaves without cyclic I/O, start in PREOP:

```elixir
{:ok, session} = EtherCAT.start(backend: backend)
:ok = EtherCAT.await_ready(session)
EtherCAT.Diagnostics.slaves(session)
:ok = EtherCAT.stop(session)
```

## 3. Read a cyclic input

Drivers are application-owned. This minimal driver reads channel 1 of an
EL1809; static endpoint metadata is optional. For shared mappings and metadata,
see the [driver authoring guide](https://hexdocs.pm/ethercat/0.5.0/EtherCAT.Driver.html).

```elixir
defmodule MyApp.EL1809 do
  @behaviour EtherCAT.Driver

  @impl true
  def signal_model(_config, _pdos), do: [ch1: EtherCAT.Driver.Signal.whole_pdo(0x1A00)]

  @impl true
  def decode_signal(_signal, _config, <<0::7, bit::1>>), do: {:ok, bit == 1}
  def decode_signal(_signal, _config, _raw), do: {:error, :invalid_data}
end
```

List slaves in physical ring order. This example assumes an EK1100 coupler
followed by an EL1809; adapt it to the hardware you discovered before starting:

```elixir
{:ok, session} = EtherCAT.start(
  backend: backend,
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

:ok = EtherCAT.await_operational(session)
EtherCAT.sample(session, :inputs, :io)
#=> {:ok, %EtherCAT.Sample{inputs: %{ch1: false}, errors: %{}, ...}}
# May return {:error, :not_ready} before the first sample arrives.

:ok = EtherCAT.stop(session)
```

Keep the returned session for every runtime call. Stopping it leaves the
host-supervised runtime alive; reusing a stopped session returns
`{:error, :stale_session}`. A sample covers one domain cycle, not a cross-domain
snapshot. Check its `errors` as well as its `inputs`.

## 4. Diagnose problems

Inspect a **live** session before stopping it:

```elixir
EtherCAT.state(session)
EtherCAT.Diagnostics.master_status(session)
EtherCAT.status(session, :inputs)
```

| Symptom | Action |
| --- | --- |
| Raw socket permission failure | Check the interface and capability on the BEAM executable actually running your app. |
| Session stays in PREOP | Use `target_state: :op` and attach signals to a domain; `await_ready/1` does not require cyclic I/O. |
| Activation fails or state is `:recovering` | Inspect master and slave status for transport, WKC, AL-state, or configuration faults. |
| Sample has decoding errors | Check the driver's mapping, bit widths, and codec; failed values are not replaced with zero or earlier values. |
| Subscriber mailbox grows | Poll with `EtherCAT.samples/2` instead; subscriptions have no backpressure or dropping. |

## Upgrade guide

For applications using `0.4.x`:

- **Supervise the runtime yourself.** Add `{EtherCAT.Runtime, []}` to the host
  supervision tree; starting the `:ethercat` application no longer starts a master.
- **Keep the session.** `EtherCAT.start/1` returns `{:ok, session}`, not `:ok`.
  Pass it to runtime, provisioning, diagnostics, signal, and capture operations.
  A stopped session returns `{:error, :stale_session}`; it never follows a restart.
- **Use an explicit backend.** Replace `interface: "eth0"` with
  `backend: {:raw, %{interface: "eth0"}}`. UDP and redundant raw configurations
  also use `EtherCAT.Backend`.

| 0.4.x call | 0.5.0 replacement |
| --- | --- |
| `EtherCAT.await_running()` | `EtherCAT.await_ready(session)`; use `await_operational(session)` for cyclic I/O |
| `EtherCAT.read_input(slave, signal)` | `EtherCAT.read(session, slave, signal)` |
| `EtherCAT.write_output(slave, signal, value)` | `EtherCAT.write(session, slave, signal, value)` |
| `EtherCAT.subscribe(slave, signal)` | `EtherCAT.Signals.subscribe(session, slave, signal)` |
| `EtherCAT.configure_slave(slave, opts)` / `activate()` / `deactivate()` | `EtherCAT.Provisioning` equivalents, with the session first |
| SDO transfers and DC lock waits on `EtherCAT` | `EtherCAT.Provisioning`, with the session first |
| Slave/domain/DC inspection on `EtherCAT` | `EtherCAT.Diagnostics`, with the session first |
| `EtherCAT.stop()` | `EtherCAT.stop(session)` |

`EtherCAT.slaves(session)` returns configured names; use
`EtherCAT.Diagnostics.slaves(session)` for detailed summaries. For coherent
per-domain observations, use `sample/3` or `subscribe/3` on `EtherCAT`.
Protocol subscriptions return `{:ok, ref, status, samples}` and deliver
`{:ethercat, ref, payload}` messages; cancel them with `unsubscribe/3`.

**Migrate custom drivers** from `EtherCAT.Slave.Driver` to `EtherCAT.Driver`.
Implement `signal_model/2` with named `EtherCAT.Driver.Signal` mappings, and
return `{:ok, value}` or `{:error, reason}` from codecs. Mailbox setup moves to
`c:EtherCAT.Driver.Provisioning.mailbox_steps/2`; consume lifecycle notifications
and latch subscriptions instead of inline driver hooks. Simulator companions
implement `EtherCAT.Simulator.Adapter` and supply an explicit profile.
See the [driver contract](https://hexdocs.pm/ethercat/0.5.0/EtherCAT.Driver.html)
and [full changelog](https://github.com/sid2baker/ethercat/blob/v0.5.0/CHANGELOG.md).

## Test without hardware

From a repository checkout:

```bash
mix deps.get
ETHERCAT_INTEGRATION_TRANSPORT=udp mix test test/integration/simulator --exclude raw_socket --exclude raw_socket_redundant --exclude raw_socket_redundant_toggle
mix test test/ethercat/driver/catalogue_example_test.exs
```

The simulator suite exercises the real master over virtual slave segments.
The driver comparison demonstrates a shared signal catalogue without changing
the public callbacks. The command above explicitly excludes raw transports.
Hardware and raw-socket tests need separate setup.

## Pick your next task

- **Write a driver:** [callback contract and catalogue pattern](https://hexdocs.pm/ethercat/0.5.0/EtherCAT.Driver.html).
- **Configure a PREOP session or use SDOs:** `EtherCAT.Provisioning`.
- **Write outputs or subscribe to observations:** `EtherCAT`; signal/latch subscriptions: `EtherCAT.Signals`.
- **Build virtual devices or inject faults:** `EtherCAT.Simulator`.
- **Capture hardware:** `iex -S mix ethercat.capture --interface eth0`; see `EtherCAT.Capture`.
- **Run hardware checks:** `MIX_ENV=test mix run test/integration/hardware/scripts/scan.exs --interface eth0`; see the [hardware guide](https://github.com/sid2baker/ethercat/blob/v0.5.0/test/integration/hardware/README.md) before running bench scripts.
- **Understand internals:** [architecture](https://github.com/sid2baker/ethercat/blob/v0.5.0/ARCHITECTURE.md). Build the API reference for your checkout with `mix docs`.
