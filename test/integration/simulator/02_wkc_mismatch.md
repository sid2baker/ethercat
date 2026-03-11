## Scenario

Cyclic working-counter mismatch during otherwise live traffic.

## Real-World Analog

One slave stops contributing to the LRW working counter, or the segment layout
no longer matches what the master believes is mapped.

## Expected Master Behavior

- Domain should stay `:cycling`, but report invalid cycle health.
- Invalid reason should be a WKC mismatch, not a timeout.
- Master should move into `:recovering`.
- Slave-local faults should remain empty unless another probe localizes the
  fault to a specific slave.
- Clearing the mismatch should let the domain recover and return the master to
  `:operational`.

## Actual Behavior Today

Observed with `Simulator.inject_fault({:next_exchanges, 6, {:wkc_offset, -1}})`:

- `EtherCAT.domain_info(:main)` reports
  `{:wkc_mismatch, %{expected: 3, actual: 2}}`
- master enters `:recovering`
- slave faults remain `nil`
- after the counted mismatch window passes, the domain returns to healthy
  cycling and the master returns to `:operational`

This also matches the intended behavior.

## Test Shape

1. boot the simulated ring to `:operational`
2. inject `{:next_exchanges, 6, {:wkc_offset, -1}}`
3. assert `:recovering`
4. assert the domain reports the expected/actual WKC mismatch
5. assert healthy cycling resumes

## Simulator API Notes

Current API is enough for coarse WKC skew coverage.

Nice follow-up API:

- target the skew at a specific command or slave contribution instead of a
  global offset across all datagrams
