## Scenario

Mailbox responses keep a valid frame shape but return the wrong mailbox header
or CoE service.

## Real-World Analog

A slave stays reachable in PREOP and answers a mailbox request, but its reply is
classified under the wrong mailbox type or wrong CoE service code.

## Expected Master Behavior

- Public SDO helpers should return the exact parser error tuple.
- The master should stay in `:preop_ready`; this is still a mailbox protocol
  fault, not a transport or topology failure.
- Clearing the injected fault should restore the same SDO call without
  restarting the session.

## Actual Behavior Today

Observed with:

- `Simulator.inject_fault({:mailbox_protocol_fault, :mailbox, 0x2001, 0x01, :upload_init, {:mailbox_type, 0x04}})`
- `Simulator.inject_fault({:mailbox_protocol_fault, :mailbox, 0x2001, 0x01, :upload_init, {:coe_service, 0x02}})`

- the first upload returns `{:error, {:unexpected_mailbox_type, 4}}`
- the second upload returns `{:error, {:unexpected_coe_service, 2}}`
- the master stays in `:preop_ready`
- after `Simulator.clear_faults/0`, the same upload succeeds again

## Test Shape

1. boot a coupler plus mailbox-capable slave to `:preop_ready`
2. inject a wrong mailbox type and assert the exact upload error
3. clear faults and verify the same upload succeeds
4. inject a wrong CoE service and assert the exact upload error
5. clear faults and verify the same upload succeeds again

## Simulator API Notes

Current API is now enough for malformed mailbox response headers through:

- `{:mailbox_protocol_fault, slave_name, index, subindex, :upload_init, {:mailbox_type, type}}`
- `{:mailbox_protocol_fault, slave_name, index, subindex, :upload_init, {:coe_service, service}}`

Still worth adding later:

- malformed segmented CoE payloads, like invalid segment padding or unexpected
  segment response bodies
