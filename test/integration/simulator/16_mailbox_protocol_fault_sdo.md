## Scenario

Mailbox responses stay transport-valid but violate CoE mailbox protocol shape.

## Real-World Analog

A slave replies over mailbox and stays reachable in PREOP, but returns a bad
mailbox counter or toggles a segmented SDO response incorrectly.

## Expected Master Behavior

- Public SDO helpers should return the exact protocol error tuple.
- The master should stay in `:preop_ready`; this is a mailbox protocol fault,
  not a transport or topology failure.
- Clearing the injected fault should restore the same SDO call without
  restarting the session.

## Actual Behavior Today

Observed with:

- `Simulator.inject_fault({:mailbox_protocol_fault, :mailbox, 0x2001, 0x01, :upload_init, :counter_mismatch})`
- `Simulator.inject_fault({:mailbox_protocol_fault, :mailbox, 0x2003, 0x01, :upload_segment, :toggle_mismatch})`

- the init-phase upload returns `{:error, {:unexpected_mailbox_counter, 1, 2}}`
- the segmented upload returns `{:error, {:toggle_mismatch, 0, 1}}`
- the master stays in `:preop_ready`
- after `Simulator.clear_faults/0`, the same uploads succeed again

## Test Shape

1. boot a coupler plus mailbox-capable slave to `:preop_ready`
2. inject an init-phase mailbox-counter mismatch and assert the exact error
3. clear faults and verify the same upload succeeds
4. inject a segmented toggle mismatch and assert the exact error
5. clear faults and verify the segmented upload succeeds again

## Simulator API Notes

Current API is now enough for mailbox protocol-shape faults through:

- `{:mailbox_protocol_fault, slave_name, index, subindex, :upload_init, :counter_mismatch}`
- `{:mailbox_protocol_fault, slave_name, index, subindex, :upload_segment, :toggle_mismatch}`

Still worth adding later:

- malformed mailbox payloads beyond valid type/service headers, like invalid
  CoE payloads or unexpected SDO commands
