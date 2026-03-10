# Runtime Model

## SOES Shape

The SOES reference exposes a very small slave runtime surface:

- initialize hardware and ESC access
- call `ecat_slv_init(&config)`
- repeatedly call `ecat_slv()`

See:

- [linux_lan9252demo/main.c](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/soes/applications/linux_lan9252demo/main.c)
- [tutorial.txt](/home/n0gg1n/Development/Work/opencode/ethercat/lib/ethercat/simulator/slave/reference/soes/soes/doc/tutorial.txt)

The `esc_cfg_t` in the demo makes the runtime responsibilities explicit:

- watchdog count
- state-change hooks
- mailbox/object hooks
- PDO override hooks
- DC checks

That tells us the slave runtime is really the combination of:

- ESC register protocol
- AL-state handling
- mailbox handling
- process-image update hooks

## Important Insight For Elixir

The Elixir test slave does **not** need a polling loop that imitates
`ecat_slv()` literally.

It only needs to preserve the observable protocol behavior:

- station-address assignment
- AL control/status transitions
- EEPROM/SII access
- SyncManager/FMMU register writes
- process-data read/write via logical addressing
- mailbox request/response behavior

So the Elixir runtime can be event-driven by incoming datagrams instead of
poll-driven by an embedded loop.

## AL-State Expectations

From the SOES tutorial and stack structure, the slave must present the normal
EtherCAT Application Layer state machine:

- `INIT`
- `PREOP`
- `SAFEOP`
- `OP`
- optional `BOOTSTRAP`

The master-facing contract is register-based:

- `AL Control` write at `0x0120`
- `AL Status` read at `0x0130`
- `AL Status Code` read at `0x0134`

For the simulator, this means:

- AL-state transitions live in simulated ESC memory/state
- successful transitions must update both state and register view
- error-injection later should set the AL error bit and status code without
  inventing new behavior outside the register contract

## Watchdog and Output Discipline

The SOES tutorial is explicit about output handling:

- outputs are only meaningful in operational output-enabled state
- watchdog expiry should invalidate outputs and drive the slave toward
  `SAFEOP` with an error

That matters for later simulator milestones, but it is **not** required for the
first happy-path deep integration test. For Milestone 1, the simulator only
needs a deterministic process-image path. Watchdog/error behavior can be added
later as fault injection.

## Mailbox and Protocol Loop

SOES runs mailbox and protocol handlers from the same main loop:

- mailbox process
- CoE process
- FoE process
- EoE/XoE process

The Elixir simulator should not model this as a permanent background loop.

Instead:

- mailbox datagrams should be handled when they arrive
- CoE behavior should be a mailbox-layer feature
- protocol state should live in simulator/slave state, not in a fake thread

That is now the implemented direction for Milestone 3:

- a mailbox-capable device advertises PREOP mailbox offsets/sizes through SII
- mailbox writes to the receive area are handled synchronously by the simulator
- the simulator raises SM1 mailbox-full when a response is ready
- reading the send mailbox clears the mailbox-full indication again

The current scope is deliberately small:

- expedited and segmented SDO upload/download
- deterministic object dictionary values
- typed object entries with access and state rules
- mailbox abort replies can be injected explicitly

Milestone 4 also adds explicit fault injection around the runtime boundary:

- no response
- wrong WKC
- slave disconnect / reconnect
- AL error latch
- retreat to `SAFEOP`
- mailbox abort replies

Later simulator generalization work adds profile-aware runtime behavior above
this protocol core:

- dynamic input refresh through a behavior boundary
- typed PDO/process-data conversion
- reusable analog, temperature, mailbox, and servo profiles
- optional DC-aware behavior for devices that need it

## Elixir Implication

The support runtime should be split into:

- `EtherCAT.Simulator.Slave.Device`
  One simulated slave state, including AL state and ESC register image.
- `EtherCAT.Simulator`
  The ring/segment executor that routes datagrams across ordered slaves.
- `EtherCAT.Simulator.Udp`
  A real socket endpoint that feeds decoded datagrams into the simulator.

This preserves the SOES responsibilities without copying the embedded control
flow.
