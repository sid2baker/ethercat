## Scenario

Boot a minimal simulator ring with a coupler and the manual-based `ATV320`
protocol driver. Exercise explicit scanner writes, coherent protocol samples,
and a later slave-local `SAFEOP` retreat on the drive.

## Why

The ATV320 driver is intentionally manual-based rather than ESI-exact. This
scenario keeps the protocol integration contract honest:

- the static driver description and coherent sample surface are present
- generic scanner words outside the named CiA402 fields still round-trip
- explicit controlword writes drive simulated statusword and velocity feedback
- a slave-local `SAFEOP` retreat does not break later protocol I/O

## API Note

Semantic CiA402 commands and projected drive state no longer belong to the
EtherCAT driver. This scenario verifies only the protocol boundary that a
separate semantic adapter will consume.

## Repair Plan

- keep this scenario as the end-to-end regression for the ATV320 protocol driver
- if it fails, patch the smallest honest layer:
  - driver signal mapping if the scanner slots drift
  - simulator companion/behavior if protocol feedback drifts
  - sample construction if a domain observation loses coherence
  - runtime recovery if the `SAFEOP` retreat stops being slave-local
- rerun this scenario and the targeted driver tests

## Expectations

1. the drive boots to AL `OP` with statusword `0x0040`
2. generic input and output scanner words still map through the runtime
3. explicit controlword writes reach the expected statuswords and target
   velocity is reflected into actual velocity
4. a later `SAFEOP` retreat on the drive stays slave-local, emits protocol
   state notifications, and does not force master recovery
5. after the retry returns the drive to AL `OP`, protocol writes and coherent
   samples continue

## Fault Description

No fault found in the current implementation. This scenario exists as a
regression guard for the ATV320 driver/runtime/simulator boundary.
