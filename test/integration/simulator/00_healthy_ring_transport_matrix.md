## Scenario

Baseline healthy transport matrix for the simulated
`EK1100 -> EL1809 -> EL2809` ring.

## Real-World Analog

Bench bring-up and transport smoke validation before any fault injection.

This models the question:

"Can the real master boot a healthy ring, exchange cyclic PDO data, and keep
doing so across the transport modes the simulator exposes?"

## Expected Master Behavior

- single-link UDP reaches `:operational`
- single-link raw reaches `:operational` when raw veth interfaces are present
- cyclic PDO loopback stays healthy in both single-link transports
- redundant raw reaches `:operational` when both raw veth pairs are present
- a single deterministic cable break in redundant raw mode does not force a
  false degraded state or break cyclic I/O

## Actual Behavior Today

The runtime behavior is already testable with the current simulator helpers.

The gap was test shape, not product behavior: the healthy baseline coverage was
split across ad hoc `ring_test.exs` files instead of a numbered scenario pair
that fits the rest of this directory.

## Test Shape

1. boot the healthy ring over UDP and assert `:operational`
2. write outputs and assert cyclic loopback over UDP
3. repeat the same boot and cyclic assertions over raw when `:raw_socket` is
   available
4. boot the redundant raw ring when `:raw_socket_redundant` is available
5. introduce one deterministic cable break and assert cyclic I/O stays healthy
6. heal the break and assert the topology returns to healthy redundant mode

## Simulator API Notes

Current API is enough.

No API change needed.
