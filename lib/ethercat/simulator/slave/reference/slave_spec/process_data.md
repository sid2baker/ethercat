# Process Data

## What The SOES Demo Implies

The SOES tutorial and Linux demo imply a standard small-slave process-data
flow:

- master drives outputs through SM2
- slave updates inputs through SM3
- PDO mapping defines which object entries are packed into those buffers
- FMMUs expose those SM buffers into the EtherCAT logical address space

Relevant sources:

- [tutorial.txt](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/soes/soes/doc/tutorial.txt)
- [slave_objectlist.c](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/soes/applications/linux_lan9252demo/slave_objectlist.c)

## Simulator Responsibilities

For the Elixir simulator, process data means:

1. store SyncManager register writes
2. store FMMU register writes
3. use the active FMMUs to match logical datagrams
4. read/write the simulated ESC/process-image bytes
5. increment WKC exactly as the master expects

That is enough to boot the real master through PREOP setup and then exchange
cyclic LRW traffic.

## Required Addressing Modes

The simulator must support, from the start:

- broadcast
- auto-increment
- fixed-address
- logical

Reason:

- startup uses broadcast and auto-increment station assignment
- later startup/verification uses fixed-address reads/writes
- cyclic domains use logical LRW/LRD/LWR datagrams

So the simulator is not “a fake one-slave LRW echo”. It has to model the real
startup addressing modes too.

## WKC Rules

The first process-data rule that must stay explicit is WKC contribution:

- read effect = `1`
- write effect = `2`
- read + write effect = `3`

For LRW on a slave with both output and input participation, the total
contribution is `3`.

The simulator should derive this from actual FMMU overlap and command effect,
not from a shortcut such as “one slave = WKC 3”.

## Initial Definition Scope

The smallest practical first device is:

- one output byte
- one input byte
- one output SM
- one input SM
- one output FMMU
- one input FMMU

That is what the current `digital_io` support device provides. It is smaller
than the SOES LAN9252 demo, but the protocol shape is the same.

## Next Realistic Step

To align even more closely with the SOES LAN9252 demo, the next device should
move toward:

- two output bytes
- one input byte
- explicit object names matching:
  - LED0
  - LED1
  - Button1

That is still small, but it mirrors the reference application better.
