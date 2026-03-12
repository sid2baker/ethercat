## Scenario

An output-slave disconnect drives the master into `:recovering`. A second
slave-local `SAFEOP` retreat is armed up front too, but it should only fire
after the master has actually entered recovery.

## Real-World Analog

One runtime fault has already forced the bus into recovery work. A second
device-side issue appears because that same recovery window has started, not
because the test process races in with a follow-up injection.

## Expected Master Behavior

- The counted output disconnect should push the master into `:recovering`.
- The `SAFEOP` retreat armed from the telemetry event
  `[:ethercat, :master, :state, :changed]` with `to: :recovering` should land
  during that same recovery interval.
- The output reconnect and the slave-local `SAFEOP` retry path should both
  clear, returning the master to `:operational`.

## Actual Behavior Today

Observed with:

1. `Fault.disconnect(:outputs) |> Fault.next(30)`
2. `Scenario.inject_fault_on_event/4` matching
   `[:ethercat, :master, :state, :changed]` with `metadata: [to: :recovering]`
   to inject `Fault.retreat_to_safeop(:inputs)`

The runtime behaves as intended:

- the first fault drives the master into `:recovering`
- the follow-up `SAFEOP` retreat lands without a second imperative test step
- both faults clear on their existing recovery paths

## Test Shape

1. boot the default simulator ring in `:op`
2. inject the counted output disconnect
3. arm the follow-up `SAFEOP` retreat on master recovery entry telemetry
4. assert the output disconnect drives `:recovering`
5. assert the inputs retreat to `SAFEOP` during that recovery window
6. assert both faults later clear and the bus returns to healthy operation
