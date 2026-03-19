## Scenario

Single-link raw ring helper must allow static raw endpoint delay config, and
clearing a transient raw delay fault must restore that configured delay.

## Real-World Analog

A lab setup may carry a fixed response delay on one raw NIC path while still
needing temporary extra delay injection to model transient congestion or
bridge jitter.

## Expected Master Behavior

- No master runtime change is needed; this scenario is about honest simulator
  setup through the shared single-link raw helper.
- The shared single-link raw ring helper can start the maintained raw simulator
  with static endpoint response-delay options.
- A temporary raw delay fault overlays the configured delay.
- Clearing raw faults removes only the temporary overlay and leaves the
  configured delay intact.
- Simulator fault queues drain cleanly after the temporary raw delay fault is
  cleared.

## Actual Behavior Today

Before the fix, `SimulatorRing.boot_operational!/1` ignored
`simulator_opts: [raw_endpoint_opts: ...]` in single-link raw mode.

The scenario could only be written by bypassing the shared ring helper and
starting `EtherCAT.Simulator` manually. Assertions about configured raw delay
failed because the helper always started the endpoint with zero configured
delay.

## Fault Classification

- the test/helper API is making the scenario awkward to write or assert

## API Note

- better test/helper API suggested
- required to land the scenario honestly now

## Fault Description

- Expected behavior: `EtherCAT.IntegrationSupport.SimulatorRing` should pass
  single-link raw endpoint options through to `EtherCAT.Simulator`, just as
  `RedundantSimulatorRing` already passes `raw_endpoint_opts` to redundant raw
  endpoints.
- Actual behavior: the single raw helper dropped those options and only passed
  the simulator interface name.
- Visible runtime impact: helper-driven raw scenarios could not model a
  statically delayed endpoint or assert post-clear restoration without
  bypassing the maintained ring harness.
- Suspected broken layer and why: test/helper API, because
  `SimulatorRing.start_simulator!/1` hard-coded single raw startup as
  `[interface: ...]`.

## Repair Plan

1. Keep the new integration test as the reproducer.
2. Extend `SimulatorRing.start_simulator!/1` to merge `raw_endpoint_opts` into
   the single raw endpoint startup options.
3. Assert configured delay, transient raw delay overlay, fault clear, and
   queue drain through public `Transport.Raw.info/0` and
   `Expect.simulator_queue_empty/0`.
4. Rerun the targeted scenario and the healthy transport matrix.

## Test Shape

1. Start the maintained single-link raw simulator through `SimulatorRing` with
   a configured raw endpoint delay.
2. Assert the configured delay is visible through
   `EtherCAT.Simulator.Transport.Raw.info/0`.
3. Inject a temporary raw delay fault through `Transport.Raw.inject_fault/1`
   and verify the effective delay reflects the overlay.
4. Clear raw faults and assert the configured delay returns.
5. Assert `Expect.simulator_queue_empty/0` succeeds and the simulator state is
   clean again.

## Simulator API Notes

- Current transport fault API is enough.
- Better test/helper API was required: `SimulatorRing` now forwards
  `raw_endpoint_opts` in single-link raw mode.
