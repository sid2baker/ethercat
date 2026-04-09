## Scenario

Boot a minimal simulator ring with a coupler and the manual-based `ATV320`
driver. Exercise the documented CiA402 command path, generic communication
scanner words, and a later slave-local `SAFEOP` retreat on the drive.

## Why

The new ATV320 driver is intentionally manual-based rather than ESI-exact. This
scenario keeps the important integration contract honest:

- the driver-backed public description and snapshot surface are present
- generic scanner words outside the named CiA402 fields still round-trip
- CiA402 command helpers drive the simulated statusword and velocity feedback
- a slave-local `SAFEOP` retreat does not break later driver command flow

## API Note

no API change needed

## Repair Plan

- keep this scenario as the end-to-end regression for the ATV320 driver
- if it fails, patch the smallest honest layer:
  - driver signal mapping if the scanner slots drift
  - simulator companion/behavior if the CiA402 feedback contract drifts
  - runtime recovery if the `SAFEOP` retreat stops being slave-local
- rerun this scenario and the targeted driver tests

## Expectations

1. the drive boots to AL `OP` while its CiA402 state starts at `switch_on_disabled`
2. generic input and output scanner words still map through the runtime
3. `shutdown -> switch_on -> enable_operation -> set_target_velocity` reaches
   `operation_enabled` and mirrors the target into actual velocity
4. a later `SAFEOP` retreat on the drive stays slave-local and does not force
   master recovery
5. after the retry returns the drive to AL `OP`, the CiA402 command path still
   works and velocity feedback resumes

## Fault Description

No fault found in the current implementation. This scenario exists as a
regression guard for the ATV320 driver/runtime/simulator boundary.
