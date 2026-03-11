## Scenario

Segmented CoE downloads begin correctly, then one of the later download-segment
acknowledgements comes back malformed.

## Real-World Analog

A slave accepts the download-init phase and at least one later segment, but a
subsequent acknowledgement returns a truncated CoE payload or an impossible
segment-ack command byte.

## Expected Master Behavior

- Public SDO helpers should return the exact parser error tuple.
- The master should stay in `:preop_ready`; this remains a mailbox protocol
  fault, not a transport or topology failure.
- A malformed mid-transfer acknowledgement should leave the object unchanged,
  because the transfer never committed.
- A malformed final acknowledgement should still surface as an error even if
  the slave had already committed the final segment before replying.

## Actual Behavior Today

Observed with:

- `Simulator.inject_fault({:after_milestone, {:mailbox_step, :mailbox, :download_segment, 1}, {:mailbox_protocol_fault, :mailbox, 0x2003, 0x01, :download_segment, :invalid_coe_payload}})`
- `Simulator.inject_fault({:after_milestone, {:mailbox_step, :mailbox, :download_segment, 2}, {:mailbox_protocol_fault, :mailbox, 0x2003, 0x01, :download_segment, {:segment_command, 0x60}}})`

- the mid-transfer download returns `{:error, :invalid_coe_response}` and does
  not mutate the object
- the final-ack download returns
  `{:error, {:unexpected_sdo_segment_command, 96}}` after the object was
  already committed
- the master stays in `:preop_ready`
- after `Simulator.clear_faults/0`, the same segmented download succeeds again

## Test Shape

1. boot a coupler plus mailbox-capable slave to `:preop_ready`
2. schedule a malformed later download acknowledgement after one successful
   segment and assert the exact parser error
3. verify the object is unchanged, clear faults, and confirm the same download
   succeeds
4. schedule a malformed final acknowledgement after two successful segments and
   assert the exact parser error
5. verify the object has already changed, clear faults, and confirm another
   clean download still succeeds

## Simulator API Notes

Current API is now enough for malformed segmented download acknowledgements
through:

- `{:after_milestone, {:mailbox_step, slave_name, :download_segment, count}, {:mailbox_protocol_fault, slave_name, index, subindex, :download_segment, :invalid_coe_payload}}`
- `{:after_milestone, {:mailbox_step, slave_name, :download_segment, count}, {:mailbox_protocol_fault, slave_name, index, subindex, :download_segment, {:segment_command, command}}}`

Still worth adding later:

- mailbox response timeouts during PREOP configuration, not just deterministic
  aborts or malformed acknowledgements
