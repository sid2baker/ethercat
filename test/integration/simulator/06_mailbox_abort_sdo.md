## Scenario

Explicit mailbox abort on a public SDO upload against a mailbox-capable slave in
PREOP.

## Real-World Analog

A smart slave remains present and reachable, but rejects a specific CoE object
access with a deterministic abort code.

## Expected Master Behavior

- `EtherCAT.upload_sdo/3` should return the SDO abort reason directly.
- The master should stay in `:preop_ready`; this is an application-level mailbox
  error, not a transport or topology failure.
- Clearing the injected abort should restore the same SDO read without requiring
  a restart.

## Actual Behavior Today

Observed with a simulated mailbox-capable slave and
`Simulator.inject_fault({:mailbox_abort, :mailbox, 0x2000, 0x01, 0x0601_0002})`:

- `EtherCAT.upload_sdo(:mailbox, 0x2000, 0x01)` returns
  `{:error, {:sdo_abort, 0x2000, 0x01, 0x0601_0002}}`
- the master remains in `:preop_ready`
- after `Simulator.clear_faults/0`, the upload succeeds again and returns the
  original object bytes

## Test Shape

1. boot a coupler plus mailbox-capable slave to `:preop_ready`
2. verify a baseline SDO upload succeeds
3. inject a mailbox abort for that index/subindex
4. assert the upload returns the exact abort tuple
5. clear faults
6. assert the upload succeeds again without restarting the session

## Simulator API Notes

Current API is enough for direct mailbox abort coverage.

Still worth adding later:

- mailbox aborts during PREOP retry paths, not just direct public SDO calls
