## Scenario

Logical working-counter mismatch caused by one named slave contribution, without
disturbing fixed-address poll traffic.

## Real-World Analog

One slave stops contributing to the logical PDO WKC even though it still
responds to direct status polling.

## Expected Master Behavior

- The domain should report a WKC mismatch, not a timeout.
- The master should enter `:recovering`.
- Slave-local health should remain clean because fixed-address polls still work.
- Once the counted skew window passes, the master should return to
  `:operational`.

## Actual Behavior Today

Observed with
`Simulator.inject_fault({:next_exchanges, 6, {:logical_wkc_offset, :outputs, -1}})`:

- `EtherCAT.domain_info(:main)` reports
  `{:wkc_mismatch, %{expected: 3, actual: 2}}`
- the master enters `:recovering`
- the outputs slave does not get marked `:down`
- after the counted skew window passes, the domain returns to healthy cycling
  and the master returns to `:operational`

## Test Shape

1. boot the simulated ring to `:operational`
2. inject a counted logical-WKC skew for the outputs slave
3. assert `:recovering`
4. assert the domain reports the expected/actual WKC mismatch
5. assert slave-local faults remain empty
6. assert healthy cycling resumes

## Simulator API Notes

Current API is now enough for targeted logical WKC skew coverage through
`{:logical_wkc_offset, slave_name, delta}`.

Still worth adding later:

- malformed segmented CoE payloads, like invalid segment padding or unexpected
  segment response bodies
