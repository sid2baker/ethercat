## Scenario

Short name and the real-world fault or condition being modeled.

## Real-World Analog

What kind of plant, cable, power, or slave behavior this corresponds to.

## Expected Master Behavior

What the master should do at a high level:

- public state transition
- domain behavior
- slave fault visibility
- recovery expectation

## Actual Behavior Today

Observed behavior from the current integration test.

If the scenario is not yet testable, say that explicitly and mark any behavior
as inference.

## Test Shape

The smallest useful integration test:

1. boot ring
2. inject or script fault
3. assert transition and diagnostics
4. clear or resolve fault
5. assert recovery

## Simulator API Notes

- `Current API is enough` or
- `Need new simulator API`

If a new API is needed, say what boundary it should live on:

- datagram execution
- slave runtime
- UDP/raw-frame transport edge
- signal wiring or fault scripting
