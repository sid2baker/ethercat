## Scenario

Mailbox-local response timeouts during public segmented SDO upload and download
against a mailbox-capable slave in PREOP.

## Real-World Analog

A smart slave stays reachable and continues answering other mailbox traffic, but
one later segment reply never appears in SM1 during a public CoE SDO helper
call.

## Expected Master Behavior

- `EtherCAT.upload_sdo/3` and `EtherCAT.download_sdo/4` should return the exact
  mailbox timeout reason directly.
- The master should stay in `:preop_ready`; this is a mailbox helper failure,
  not a transport or topology fault.
- A mid-transfer download timeout should leave the object unchanged.
- Clearing the injected fault should restore the same public SDO helper without
  restarting the session.

## Actual Behavior Today

Observed with a simulated mailbox-capable slave and:

- `Simulator.inject_fault(Fault.mailbox_protocol_fault(:mailbox, 0x2003, 0x01, :upload_segment, :drop_response) |> Fault.after_milestone(Fault.mailbox_step(:mailbox, :upload_segment, 2)))`
- `Simulator.inject_fault(Fault.mailbox_protocol_fault(:mailbox, 0x2003, 0x01, :download_segment, :drop_response) |> Fault.after_milestone(Fault.mailbox_step(:mailbox, :download_segment, 1)))`

- `EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)` returns
  `{:error, :response_timeout}`
- `EtherCAT.Provisioning.download_sdo(:mailbox, 0x2003, 0x01, binary)` returns
  `{:error, :response_timeout}`
- the master remains in `:preop_ready`
- the timeouted download leaves the original object value intact
- after `Simulator.clear_faults/0`, both helpers succeed again without
  restarting the session

## Test Shape

1. boot a coupler plus mailbox-capable slave to `:preop_ready`
2. arm an upload-segment dropped response after successful segment progress
3. assert the public upload helper returns `:response_timeout`
4. clear faults and verify the same upload succeeds again
5. arm a download-segment dropped response after successful segment progress
6. assert the public download helper returns `:response_timeout`
7. verify the object did not mutate and the master stayed in `:preop_ready`
8. clear faults and verify the same download succeeds again

## Simulator API Notes

Current API is now enough for mailbox-local response timeouts through public
SDO helpers with:

- `Fault.mailbox_protocol_fault(slave_name, index, subindex, stage, :drop_response)`
- `Fault.after_milestone(fault, Fault.mailbox_step(slave_name, step, count))`

Still worth adding later:

- mailbox aborts during PREOP retry paths, not just direct public SDO calls
