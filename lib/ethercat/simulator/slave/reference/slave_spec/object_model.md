# Object Model

## Reference Device

The most useful SOES example for the initial Elixir simulator is the small
Linux LAN9252 demo:

- [slave_objectlist.c](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/soes/applications/linux_lan9252demo/slave_objectlist.c)
- [utypes.h](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/soes/applications/linux_lan9252demo/utypes.h)

It is intentionally small and maps cleanly to the kind of first deep test this
repo needs.

## Process Image

From `utypes.h`, the process image is:

- Inputs:
  - `Buttons.Button1` (`uint8_t`)
- Outputs:
  - `LEDs.LED0` (`uint8_t`)
  - `LEDs.LED1` (`uint8_t`)
- Parameters:
  - `Parameters.Multiplier` (`uint32_t`)

So the device shape is:

- a small output bank
- a small input bank
- at least one non-PDO parameter value in the object dictionary

The simulator now carries that object-dictionary idea explicitly for
mailbox-capable devices:

- the internal mailbox-capable profile exposes a small deterministic object
  dictionary
- current deep tests use `0x2000:01`
- values are stored as raw binaries because the public CoE API also works with
  raw binary payloads

## Object Dictionary

The demo object dictionary includes:

- identity objects:
  - `0x1000`
  - `0x1008`
  - `0x1009`
  - `0x100A`
  - `0x1018`
- PDO mapping objects:
  - `0x1600`
  - `0x1A00`
- SyncManager communication/assignment:
  - `0x1C00`
  - `0x1C12`
  - `0x1C13`
- process-data objects:
  - `0x6000`
  - `0x7000`
- parameter object:
  - `0x8000`

For the Elixir simulator, the first milestone does **not** need the whole CoE
surface. But these objects tell us what the device should conceptually model.

## PDO Layout

From `slave_objectlist.c`:

- RxPDO `0x1600`
  - `0x7000:01` (LED0, 8 bit)
  - `0x7000:02` (LED1, 8 bit)
- TxPDO `0x1A00`
  - `0x6000:01` (Button1, 8 bit)

So the reference SOES example is:

- 16 bits of output PDO data
- 8 bits of input PDO data

The simulator now carries that shape through its mailbox-capable profile:

- 16 bits of output PDO data
- 8 bits of input PDO data
- signal naming exposed through:
  - `led0`
  - `led1`
  - `button1`

That profile is now an internal default provider. Public simulator use should
prefer `EtherCAT.Simulator.Slave.from_driver/2`, so simulated devices stay
aligned with the real driver modules they represent.

## SyncManager Assignment

From the same object dictionary:

- `0x1C12` assigns RxPDO `0x1600` to SyncManager 2
- `0x1C13` assigns TxPDO `0x1A00` to SyncManager 3

This matches the standard EtherCAT shape the master already expects:

- SM2 for outputs
- SM3 for inputs

So the current Elixir simulator design is aligned with the SOES reference
there.

## What To Carry Into Elixir

The important specification to carry over is not the exact objectlist arrays,
but the semantic device shape:

- one declarative device describes identity and process image
- PDO assignments stay explicit
- SyncManager direction stays explicit
- process-image bytes map back to named signals in the driver

That is why the current compiled test-support split is sensible:

- `EtherCAT.Simulator.Slave.Definition`
  Declarative device identity and SII/process-image definition.
- `EtherCAT.Simulator.Slave.Driver`
  Tiny driver that gives the master named signals for tests.
- `EtherCAT.Simulator.Slave.Runtime.Device`
  Actual register/process-image state.

For Milestone 3, `Device` also owns the current mailbox-backed object
dictionary state so SDO downloads can mutate later uploads deterministically.
