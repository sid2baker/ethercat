## Scenario

One PDO-participating slave drops off the ring and later reconnects, with slave
health polling enabled.

## Real-World Analog

An I/O terminal loses power, a field cable goes intermittent, or a connector is
 briefly open and then restored.

## Expected Master Behavior

- Domain should first see a WKC mismatch because the cyclic image is incomplete.
- The affected slave's health poll should later observe `wkc=0` and report the
  slave as down.
- Master should stay in `:recovering` until both the domain and the slave fault
  are healed.
- After reconnect, the slave should rebuild itself back through `:preop`, then
  the master should request `:op` and clear the slave fault.

## Actual Behavior Today

Observed with `Simulator.inject_fault({:next_exchanges, 30, {:disconnect, :outputs}})` and
`output_health_poll_ms: 20`:

- the domain first reports `{:wkc_mismatch, %{expected: 3, actual: 1}}`
- master enters `:recovering`
- the outputs slave health poll later reports `wkc=0` and the slave fault
  becomes `{:down, :disconnected}`
- after the counted disconnect window ends, the outputs slave reports
  reconnect, the slave rebuilds through `:preop`, the master returns it to
  `:op`, and the session returns to `:operational`
- PDO traffic works again after reconnect

The architectural nuance still matters:

- without `health_poll_ms`, this fault only looks like a domain WKC problem
- with `health_poll_ms`, the same fault exercises the slave-down and reconnect
  path too

## Test Shape

1. boot the ring with `health_poll_ms` enabled on the disconnected slave
2. inject `{:next_exchanges, 30, {:disconnect, :outputs}}`
3. assert `:recovering`
4. assert the outputs slave fault becomes `{:down, :disconnected}`
5. assert the outputs slave fault clears and the master returns to
   `:operational`
6. assert PDO traffic works again after reconnect

## Simulator API Notes

Current API is enough for counted disconnect windows and richer scripted
timelines through `{:fault_script, steps}`.
