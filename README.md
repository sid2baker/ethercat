# Ethercat

Architectural scaffolding for a pure Elixir EtherCAT master. The current build
focuses on providing the OTP structure, driver DSL, public API, and protocol
layer boundaries described in the design blueprint. The wire-protocol backend
is presently implemented as a loopback device so higher layers can be developed
without needing physical hardware attached at all times.

## Quick Start

```
# Quick finite IO test (no SIGTERM needed)
mix run --no-start examples/io_quick.exs --interface enp0s31f6
```

You will need `CAP_NET_RAW` (or root) on the specified interface. The example
configures SyncManagers and FMMUs, then uses logical LWR/LRD datagrams to write
EL2809 outputs and read EL1809 inputs.

Useful flags:

```
mix run --no-start examples/io_quick.exs --interface enp0s31f6 --verbose
mix run --no-start examples/io_quick.exs --interface enp0s31f6 --dump-sm --cycles 1
mix run --no-start examples/io_quick.exs --interface enp0s31f6 --physical
```

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `ethercat` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ethercat, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can be
found at <https://hexdocs.pm/ethercat>.
