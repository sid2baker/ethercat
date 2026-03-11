## Scenario

Mailbox faults wait on successful segmented-transfer progress instead of firing
on the very next matching segment.

## Real-World Analog

A slave serves part of a large CoE SDO transfer successfully, then later aborts
only after a known number of upload or download segments have completed.

## Expected Master Behavior

- The exact SDO abort reason should still surface to the caller.
- The master should stay in `:preop_ready`; this remains a mailbox/application
  fault, not a transport or topology fault.
- The new timing should be expressible without sleeps or custom device logic.
- Clearing faults should allow the same transfer to complete again.

## Actual Behavior Today

Observed with:

- `Simulator.inject_fault({:after_milestone, {:mailbox_step, :mailbox, :upload_segment, 2}, {:mailbox_abort, :mailbox, 0x2003, 0x01, 0x0800_0000, :upload_segment}})`
- `Simulator.inject_fault({:after_milestone, {:mailbox_step, :mailbox, :download_segment, 2}, {:mailbox_abort, :mailbox, 0x2003, 0x01, 0x0800_0000, :download_segment}})`

- the simulator waits until two successful segmented mailbox steps have
  completed on the mailbox slave
- the third matching segment aborts with the exact SDO abort tuple
- the master stays in `:preop_ready`
- after clearing faults, the same multi-segment transfer succeeds again

## Test Shape

1. boot a coupler plus mailbox-capable slave to `:preop_ready`
2. inject a milestone-scheduled upload-segment abort
3. assert the large segmented upload aborts only after the milestone is met
4. clear faults and assert the upload succeeds again
5. inject a milestone-scheduled download-segment abort
6. assert the large segmented download aborts only after the milestone is met
7. clear faults and assert the download succeeds again

## Simulator API Notes

Current API is now enough for mailbox-progress timing through:

- `{:after_milestone, {:mailbox_step, slave_name, :upload_segment, count}, fault}`
- `{:after_milestone, {:mailbox_step, slave_name, :download_segment, count}, fault}`
- `{:wait_for_milestone, {:mailbox_step, slave_name, step, count}}`

Still worth adding later:

- mailbox protocol-shape faults like toggle or mailbox-counter mismatches
