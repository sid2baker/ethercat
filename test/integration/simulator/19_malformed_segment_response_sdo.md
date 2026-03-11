## Scenario

Segmented CoE uploads begin correctly, then later return malformed segment
response bodies.

## Real-World Analog

A slave answers the upload-init phase and starts a segmented upload, but one of
the later segment responses carries impossible padding bits or an unexpected
segment command byte.

## Expected Master Behavior

- Public SDO helpers should return the exact segment-parser error tuple.
- The master should stay in `:preop_ready`; this remains a mailbox protocol
  fault, not a transport or topology failure.
- Clearing the injected fault should restore the same segmented upload without
  restarting the session.

## Actual Behavior Today

Observed with:

- `Simulator.inject_fault({:mailbox_protocol_fault, :mailbox, 0x2003, 0x01, :upload_segment, :invalid_segment_padding})`
- `Simulator.inject_fault({:mailbox_protocol_fault, :mailbox, 0x2003, 0x01, :upload_segment, {:segment_command, 0x20}})`

- the first upload returns `{:error, {:invalid_segment_padding, 7}}`
- the second upload returns `{:error, {:unexpected_sdo_segment_command, 32}}`
- the master stays in `:preop_ready`
- after `Simulator.clear_faults/0`, the same segmented upload succeeds again

## Test Shape

1. boot a coupler plus mailbox-capable slave to `:preop_ready`
2. inject invalid segmented padding and assert the exact upload error
3. clear faults and verify the same segmented upload succeeds
4. inject an unexpected segment command and assert the exact upload error
5. clear faults and verify the same segmented upload succeeds again

## Simulator API Notes

Current API is now enough for malformed segmented upload responses through:

- `{:mailbox_protocol_fault, slave_name, index, subindex, :upload_segment, :invalid_segment_padding}`
- `{:mailbox_protocol_fault, slave_name, index, subindex, :upload_segment, {:segment_command, command}}`

Still worth adding later:

- malformed segmented download acknowledgements, not just upload-segment
  responses
