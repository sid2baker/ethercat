# Ethercat

Architectural scaffolding for a pure Elixir EtherCAT master. The current build
focuses on providing the OTP structure, driver DSL, public API, and protocol
layer boundaries described in the design blueprint. The wire-protocol backend
is presently implemented as a loopback device so higher layers can be developed
without needing physical hardware attached at all times.

## Quick Start

```elixir
config = %{
  interface: "eth0",
  devices: [
    %{name: :example_device, position: 0, driver: Example.Driver}
  ]
}

{:ok, bus} = Ethercat.start(config)
{:error, :unknown_signal} = Ethercat.read(bus, :example_device, :channel_1)
```

The `Example.Driver` module is authored with `use Ethercat.Driver` and declares
inputs/outputs that will be mapped into the runtime directory. As the transport
layer matures, these APIs will begin interacting with actual EtherCAT slaves.

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
