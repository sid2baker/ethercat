## Scenario

Mailbox responses keep a valid mailbox frame but return malformed CoE payloads.

## Real-World Analog

A slave stays reachable in PREOP and replies through mailbox, but the CoE
payload itself is truncated or carries an unexpected SDO command byte.

## Expected Master Behavior

- Public SDO helpers should return the exact parser error tuple.
- The master should stay in `:preop_ready`; this remains a mailbox protocol
  fault, not a transport or topology failure.
- Clearing the injected fault should restore the same SDO call without
  restarting the session.

## Actual Behavior Today

Observed with:

- `Simulator.inject_fault({:mailbox_protocol_fault, :mailbox, 0x2001, 0x01, :upload_init, :invalid_coe_payload})`
- `Simulator.inject_fault({:mailbox_protocol_fault, :mailbox, 0x2001, 0x01, :upload_init, {:sdo_command, 0x60}})`

- the first upload returns `{:error, :invalid_coe_response}`
- the second upload returns `{:error, {:unexpected_sdo_command, 96}}`
- the master stays in `:preop_ready`
- after `Simulator.clear_faults/0`, the same upload succeeds again

## Test Shape

1. boot a coupler plus mailbox-capable slave to `:preop_ready`
2. inject an invalid CoE payload and assert the exact upload error
3. clear faults and verify the same upload succeeds
4. inject an unexpected SDO command and assert the exact upload error
5. clear faults and verify the same upload succeeds again

## Simulator API Notes

Current API is now enough for malformed CoE payloads through:

- `{:mailbox_protocol_fault, slave_name, index, subindex, :upload_init, :invalid_coe_payload}`
- `{:mailbox_protocol_fault, slave_name, index, subindex, :upload_init, {:sdo_command, command}}`

Still worth adding later:

- malformed segmented CoE payloads, like invalid segment padding or unexpected
  segment response bodies
