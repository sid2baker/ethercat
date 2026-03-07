# EtherCAT

[![Hex version](https://img.shields.io/hexpm/v/ethercat.svg)](https://hex.pm/packages/ethercat)
[![Hexdocs](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/ethercat)
[![License](https://img.shields.io/hexpm/l/ethercat)](https://github.com/sid2baker/ethercat/blob/main/LICENSE)

<!-- gif goes here -->

Pure-Elixir EtherCAT master built on OTP. Runs over a standard Ethernet
interface with no RTOS, no kernel patch, and no proprietary NIC driver.

**Nerves-first** — designed for [Nerves](https://nerves-project.org/) embedded
systems with [VintageNet](https://github.com/nerves-networking/vintage_net).
Standard Linux is supported when VintageNet is configured; bare Linux without
VintageNet is not.

**Good fit:** discrete I/O, Beckhoff terminal stacks, 1 ms to 10 ms cyclic loops, diagnostics tooling.

**Not the right fit:** sub-millisecond hard real-time control.

## Try It in Livebook

[`kino_ethercat`](https://github.com/sid2baker/kino_ethercat) provides
interactive Livebook cells for bus discovery, I/O control, and diagnostics —
the fastest way to explore a live ring.

## Installation

```elixir
def deps do
  [{:ethercat, "~> 0.1.0"}]
end
```

You need `CAP_NET_RAW` or root for raw socket access:

```bash
sudo setcap cap_net_raw+ep _build/dev/lib/ethercat/priv/raw_socket
```

## Quick Start

```elixir
# Discover the ring
EtherCAT.start(interface: "eth0")
EtherCAT.await_running()
EtherCAT.slaves()
#=> [%{name: :slave_0, station: 0x1000, pid: #PID<...>}, ...]
EtherCAT.stop()
```

```elixir
# Exchange cyclic PDOs
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
    %EtherCAT.Slave.Config{name: :inputs, driver: MyApp.EL1809, process_data: {:all, :io}}
  ]
)

EtherCAT.await_operational()
EtherCAT.subscribe(:inputs, :ch1)   # receive {:ethercat, :signal, :inputs, :ch1, value}
{:ok, bit} = EtherCAT.read_input(:inputs, :ch1)
```

Full API and guides: [hexdocs.pm/ethercat](https://hexdocs.pm/ethercat)
