## Scenario

Explicit mailbox abort on a segmented public SDO transfer against a
mailbox-capable slave in PREOP.

## Real-World Analog

A smart slave remains present and reachable, starts a segmented CoE transfer,
and then aborts mid-upload or mid-download with a deterministic SDO abort code.

## Expected Master Behavior

- `EtherCAT.upload_sdo/3` and `EtherCAT.download_sdo/4` should return the exact
  SDO abort reason.
- The master should stay in `:preop_ready`; this is an application-level
  mailbox error, not a transport or topology failure.
- Clearing the injected abort should restore the same transfer without
  requiring a restart.

## Actual Behavior Today

Observed with a simulated mailbox-capable slave and:

- `Simulator.inject_fault({:mailbox_abort, :mailbox, 0x2002, 0x01, 0x0800_0000, :upload_segment})`
- `Simulator.inject_fault({:mailbox_abort, :mailbox, 0x2002, 0x01, 0x0800_0000, :download_segment})`

- a segmented upload returns `{:error, {:sdo_abort, 0x2002, 0x01, 0x0800_0000}}`
- a segmented download returns the same abort tuple without changing the object
  value
- the master remains in `:preop_ready`
- after `Simulator.clear_faults/0`, the upload and download succeed again

## Test Shape

1. boot a coupler plus mailbox-capable slave to `:preop_ready`
2. verify a baseline segmented upload succeeds
3. inject an upload-segment abort and assert the exact abort tuple
4. clear faults and verify the segmented upload succeeds again
5. inject a download-segment abort and assert the exact abort tuple
6. verify the mailbox object was not updated by the aborted transfer
7. clear faults and verify the segmented download succeeds again

## Simulator API Notes

Current API is now enough for mid-transfer mailbox abort coverage through:

- `{:mailbox_abort, slave_name, index, subindex, abort_code, :upload_segment}`
- `{:mailbox_abort, slave_name, index, subindex, abort_code, :download_segment}`

Still worth adding later:

- mailbox protocol-shape faults like toggle or mailbox-counter mismatches
