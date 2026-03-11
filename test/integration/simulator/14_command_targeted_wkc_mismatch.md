## Scenario

Configured-address poll traffic loses WKC while cyclic logical PDO traffic stays
healthy.

## Real-World Analog

One slave still participates in LRW process data, but direct configured-address
polls against it start returning an unexpected WKC.

## Expected Master Behavior

- The logical domain should stay healthy because LRW is unaffected.
- The affected slave's health poll should still localize the fault and mark the
  slave down.
- The master should enter `:recovering` for the slave-local runtime fault.
- Once the counted command-specific skew window passes, the slave should
  reconnect and return to `:op`.

## Actual Behavior Today

Observed with
`Simulator.inject_fault({:next_exchanges, 100, {:command_wkc_offset, :fprd, -1}})`:

- the logical domain stays `:healthy`
- the outputs slave health poll reports `wkc=0` and the slave fault becomes
  `{:down, :disconnected}`
- the master enters `:recovering` because of the slave-local fault, not a domain
  LRW mismatch
- after the counted skew window passes, the outputs slave reconnects and the
  master returns to `:operational`

## Test Shape

1. boot the ring with health polling enabled on the outputs slave
2. inject counted `:fprd` WKC skew
3. assert the domain stays healthy while the outputs slave is marked down
4. assert the master enters `:recovering` for the slave-local fault
5. assert the outputs slave reconnects and the master returns to `:operational`

## Simulator API Notes

Current API is now enough for command-targeted WKC skew through
`{:command_wkc_offset, command_name, delta}`.

Still worth adding later:

- malformed mailbox payloads beyond valid type/service headers, like invalid
  CoE payloads or unexpected SDO commands
