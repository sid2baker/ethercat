# Test Slave Spec

This folder contains the working specification for the Elixir simulator slave
and
simulator support code.

It is **derived from the vendored SOES reference**, not copied from it.

The goal is to capture the parts of SOES that matter for this repo's
deep-integration tests:

- EtherCAT startup and AL-state behavior
- object dictionary and process-image layout
- SyncManager/PDO expectations
- the minimum mailbox/CoE shape for later milestones

This is the current map:

- [runtime.md](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/slave_spec/runtime.md)
  Runtime loop, AL-state flow, and the slave-side responsibilities that SOES keeps
  in `ecat_slv()`.
- [object_model.md](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/slave_spec/object_model.md)
  Object dictionary, PDO assignments, and process-image structure derived from
  the `linux_lan9252demo`.
- [process_data.md](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/slave_spec/process_data.md)
  SyncManager/FMMU/process-data consequences for the Elixir simulator.
- [elixir_target.md](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/slave_spec/elixir_target.md)
  What to implement in Elixir now, what to defer, and how the SOES concepts map
  to the simulator modules in `lib/ethercat/simulator*`.

## Source Material

Primary SOES inputs:

- [README.md](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/soes/README.md)
- [tutorial.txt](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/soes/soes/doc/tutorial.txt)
- [main.c](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/soes/applications/linux_lan9252demo/main.c)
- [slave_objectlist.c](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/soes/applications/linux_lan9252demo/slave_objectlist.c)
- [utypes.h](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/soes/applications/linux_lan9252demo/utypes.h)

Secondary core-stack references when needed:

- [ecat_slv.c](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/soes/soes/ecat_slv.c)
- [esc.c](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/soes/soes/esc.c)
- [esc_eep.c](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/soes/soes/esc_eep.c)
- [esc_coe.c](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/soes/soes/esc_coe.c)

## Rule

Translate SOES concepts into deterministic BEAM-side simulator behavior.

Do not mirror the C structure 1:1 just because SOES uses it.
