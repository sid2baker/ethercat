# Simulator Runtime Refactor

## Status

Completed

## Goal

Refactor `EtherCAT.Simulator` and `EtherCAT.Simulator.Slave.Runtime.Device` so the
public simulator API stays stable while the internal runtime becomes easier to
audit, extend, and align with the EtherCAT protocol model.

This plan is intentionally structural. It should not change the external
simulator contract unless a clearer public API falls out naturally from the
decomposition.

## Public API Direction

The simulator should optimize for simulating real hardware through real driver
modules.

Preferred public path:

- `EtherCAT.Simulator.Slave.from_driver/2`

Profile-style builders were intentionally pushed behind the public API. The
simulator now leads with driver-backed device creation instead of generic
constructor helpers.

This means:

- real drivers should carry identity and signal modeling only
- simulator docs should lead with driver-backed device creation
- simulator-specific authored defaults should live in simulator-side adapters,
  not real-driver callbacks

## Why This Exists

The simulator is now a real library feature, not just test support. Two modules
have become the main pressure points:

- `lib/ethercat/simulator.ex`
- `lib/ethercat/simulator/slave/device.ex`

They still work, but they now mix too many concerns:

- datagram routing
- fault injection
- signal wiring and subscriptions
- AL/ESC state handling
- EEPROM and ESC memory hydration
- mailbox / CoE handling
- logical FMMU overlap and process image mutation

The next step is to split those concerns into explicit collaborators while
keeping the current deep integration coverage green.

## Design Decision: Reuse `EtherCAT.Slave.ESC.Registers`

Yes, selectively.

`lib/ethercat/slave/esc/registers.ex` should be reused for:

- register addresses
- SM/FMMU register offsets
- AL and watchdog decode helpers
- register tuple helpers like `sm_status/1`, `sm_activate/1`, `fmmu/1`

It should not become the simulator's only abstraction for:

- EEPROM image generation
- ESC memory hydration policy
- AL transition behavior
- mailbox semantics
- logical overlap behavior

So the plan is:

- keep `EtherCAT.Slave.ESC.Registers` as the shared source of register layout
- move simulator-specific ESC image building into simulator-owned modules
- remove hardcoded ESC addresses from `Device` where the register helper already
  has the correct named accessor

## Target Shape

### Top-level simulator runtime

`EtherCAT.Simulator` should shrink into a thin simulator state-machine module.

Target collaborators:

- `EtherCAT.Simulator.Runtime.Router`
  - executes datagrams against devices
  - owns AP/FP/BR/logical routing and WKC accumulation
- `EtherCAT.Simulator.Runtime.Faults`
  - fault injection state and transformation rules
- `EtherCAT.Simulator.Runtime.Wiring`
  - signal connections and propagated value updates
- `EtherCAT.Simulator.Runtime.Subscriptions`
  - subscriber registration, monitor bookkeeping, and event fanout

### Slave device runtime

`EtherCAT.Simulator.Slave.Runtime.Device` should stop being the implementation site for
every protocol concern.

Target collaborators:

- `EtherCAT.Simulator.Slave.Runtime.AL`
  - AL request decoding
  - transition validation
  - AL status / status-code updates
- `EtherCAT.Simulator.Slave.Runtime.ESCImage`
  - ESC register memory hydration
  - EEPROM/SII image generation
  - use `EtherCAT.Slave.ESC.Registers` for named offsets
- `EtherCAT.Simulator.Slave.Runtime.ProcessImage`
  - input/output image reads and writes
  - signal extraction and replacement
  - mirror behavior
- `EtherCAT.Simulator.Slave.Runtime.Logical`
  - active FMMU parsing
  - logical overlap application
  - WKC increment rules for LRD/LWR/LRW
- `EtherCAT.Simulator.Slave.Runtime.Dictionary`
  - object dictionary fetch/store helpers
  - mailbox abort-code override lookup
- `EtherCAT.Simulator.Slave.Runtime.CoE`
  - CoE request handling
  - mailbox upload/download session state

`Device` then becomes the coordinator for one simulated slave instance.

### Real-device simulation boundary

The simulator should stay aligned with the real driver layer.

Preferred authored flow:

- real driver implements `identity/0`
- real driver implements `signal_model/1`
- optional companion simulator adapter provides simulator-specific definition
  options
- simulator builds a device from those driver-backed declarations through
  `EtherCAT.Simulator.Slave.from_driver/2`

Profiles remain useful internally, but they should read as reusable defaults
behind the real-device path rather than the primary public modeling API.

## Coordination Rules

These rules should stay explicit during the refactor so responsibilities do not
blur again.

### `prepare/1`

`Device.prepare/1` remains a device concern.

- `Router` is responsible for calling `Device.prepare/1` before datagram
  execution begins for a given cycle
- `Simulator` should not pre-walk devices itself once `Router` exists
- `prepare/1` should stay the entry point for behavior ticks and input refresh

### Wiring propagation

`Wiring` should prefer a pure planning interface.

Target shape:

- `Wiring` inspects device signal values and connections
- `Wiring` returns a list of mutations or a transformed device set
- `Simulator` applies the result and then hands it to `Subscriptions`

Avoid making `Wiring` a second process-aware API layer.

### AL vs. ProcessImage

AL state continues to own transition legality.

`ProcessImage` owns byte/bit mutation only. It should not decide whether a
state allows a mutation. If state-dependent access rules matter, `Device`
coordinates them by asking `AL` first and delegating the actual image mutation
to `ProcessImage`.

### Logical routing

`Logical` should not become another god module.

Preferred shape:

- `Logical` parses active FMMUs and resolves overlaps
- `Logical` returns structured operations such as:
  - `{:read, phys_offset, length}`
  - `{:write, phys_offset, binary}`
  - `{:wkc, delta}`
- `Device` or a thin coordinator applies those operations through the correct
  subsystem (`ProcessImage`, mailbox, etc.)

That keeps FMMU overlap and WKC rules isolated without duplicating process
image or mailbox behavior inside `Logical`.

## Phases

### Phase 1: Router split

Extract datagram execution out of `EtherCAT.Simulator`.

Scope:

- create `EtherCAT.Simulator.Runtime.Router`
- move command dispatch constants and datagram routing there
- move WKC offset adjustment there
- make `Router` the place that calls `Device.prepare/1`
- keep the public `EtherCAT.Simulator.process_datagrams/2` unchanged

Acceptance:

- no behavior change
- all current integration tests stay green

Notes:

- This is the most mechanical extraction and should land before other runtime
  splits.

### Phase 2: Wiring and subscriptions split

Extract non-protocol simulator runtime concerns out of `EtherCAT.Simulator`.

Scope:

- move fault injection state helpers to `EtherCAT.Simulator.Runtime.Faults`
- move connections and signal propagation to `EtherCAT.Simulator.Runtime.Wiring`
- move subscriber/monitor bookkeeping to `EtherCAT.Simulator.Runtime.Subscriptions`
- keep `EtherCAT.Simulator.connect/3`, `disconnect/3`, `connections/1`,
  `subscribe/4`, and `unsubscribe/4` unchanged

Acceptance:

- widget-facing signal propagation behavior stays identical
- no direct monitor bookkeeping remains in `EtherCAT.Simulator`
- fault injection state no longer lives inline in `EtherCAT.Simulator`

### Phase 3: ESC image split

Extract EEPROM and ESC memory hydration out of `Device`.

Scope:

- create `EtherCAT.Simulator.Slave.Runtime.ESCImage`
- move:
  - `build_memory/2`
  - `build_eeprom/1`
  - DC register initialization
  - mailbox SM category generation
  - PDO category generation
- use `EtherCAT.Slave.ESC.Registers` named offsets where possible

Acceptance:

- `Device.new/2` no longer builds raw memory inline
- register addresses are not duplicated where `Registers` already provides them
- `ESCImage` becomes the only place that knows how a `Definition` becomes ESC
  memory and EEPROM bytes

### Phase 4: AL and process-image split

Extract AL state logic and signal/image mutation out of `Device`.

Scope:

- create `EtherCAT.Simulator.Slave.Runtime.AL`
- create `EtherCAT.Simulator.Slave.Runtime.ProcessImage`
- move:
  - AL request decode/validate/apply
  - AL status encoding
  - signal extraction/replacement
  - output-side effects trigger point
  - input refresh / mirror logic

Acceptance:

- `Device` no longer owns raw bit/byte mutation helpers directly
- AL transition rules are isolated and easier to compare with the protocol model
- state-dependent access policy stays coordinated explicitly by `Device` + `AL`,
  not hidden inside byte-mutation helpers

### Phase 5: Logical and mailbox split

Extract the remaining protocol-heavy subsystems from `Device`.

Scope:

- create `EtherCAT.Simulator.Slave.Runtime.Logical`
- create `EtherCAT.Simulator.Slave.Runtime.Dictionary`
- create `EtherCAT.Simulator.Slave.Runtime.CoE`
- move:
  - FMMU parsing
  - logical overlap planning
  - object entry read/write helpers
  - mailbox read/write helpers
  - upload/download session manipulation

Acceptance:

- `Device` is primarily a coordinator over AL, ESC image, process image,
  logical routing, objects, and CoE
- `Logical` no longer performs direct process-image or mailbox mutation inline
- mailbox responsibilities are clearly split between:
  - existing `Mailbox` frame parsing/encoding
  - new `CoE` upload/download orchestration

Notes:

- This is the hardest phase and should be designed before code movement starts.
- The existing `EtherCAT.Simulator.Slave.Runtime.Mailbox` module should remain the frame
  and mailbox-wire helper. `CoE` should sit above it, not replace it.

### Phase 6: Public API polish

Use the new structure to tighten the public simulator surface for tooling.

Scope:

- add stable snapshot helpers for widget and tooling use:
  - `device_snapshot/2`
  - `signal_snapshot/3`
  - `connection_snapshot/1`
- avoid exposing internal maps accidentally
- document the public simulator/device API more explicitly in:
  - `lib/ethercat/simulator.md`
  - `lib/ethercat/simulator/README.md`
- make the docs/examples prefer `from_driver/2` and treat profile builders as
  secondary convenience APIs

Acceptance:

- simulator widget consumers can use documented API only
- the public docs make it clear that the simulator is primarily for real-device
  simulation via drivers
- internals remain private

## Testing Strategy

Keep the current test pyramid intact throughout:

- unit coverage for the new helper modules
- repository integration coverage in `test/integration/hardware/`
- existing mailbox, segmented CoE, recovery, and wiring tests must remain green

Add focused unit tests for:

- logical WKC rules
- AL transition validation
- ESC image generation against register helper offsets
- wiring propagation without the full simulator process

## Non-goals

This plan does not add:

- new simulator profiles
- raw-socket simulator transport
- full DC timing simulation
- link/carrier simulation

Those are separate feature lines.

## Exit Criteria

This plan is done when:

1. `EtherCAT.Simulator` is mostly process coordination and public API
2. `EtherCAT.Simulator.Slave.Runtime.Device` is mostly device coordination
3. `EtherCAT.Slave.ESC.Registers` is reused for named register layout where it
   fits, without leaking simulator policy into that module
4. `mix test` and `mix docs` remain green throughout
5. `EtherCAT.Simulator.Slave.Runtime.Device` is materially smaller than today
   (target: well below 500 lines, not ~1000)
