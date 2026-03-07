# Rules for working with EtherCAT

## Understanding EtherCAT

EtherCAT is a pure-Elixir EtherCAT master library for automation workloads. It provides
a declarative approach to bus configuration with a slave driver behaviour at the center.
Read the module documentation before using any feature. Do not assume this library works
like other fieldbus stacks — the abstractions and startup sequence are EtherCAT-specific.

The `EtherCAT` module is the public API entry point. Slave behaviour is implemented via
`EtherCAT.Slave.Driver`. Domain cycling, signal subscriptions, and SDO transfers all have
their own conventions — consult the relevant module docs.
