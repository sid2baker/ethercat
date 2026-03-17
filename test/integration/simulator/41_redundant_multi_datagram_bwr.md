## Scenario

Multi-datagram BWR transactions in redundant mode must return wkc > 0 for
all processed registers, despite AF_PACKET outgoing echoes racing with real
cross-delivery responses.

## Real-World Analog

During master startup, `init_default_reset` sends 13 BWR datagrams in a
single frame to reset all slaves. On AF_PACKET raw sockets, outgoing echoes
(kernel loopback copies of TX frames) can arrive before the real processed
response from the ring. Echoes have wkc=0 and may carry a source MAC that
doesn't match either NIC, causing `:unknown` classification. Without proper
echo filtering, two echoes can complete the exchange before the real response.

## Expected Master Behavior

- All required BWR datagrams return wkc > 0 (slaves processed them).
- The content-based echo filter (`echo_copy?`) discards outgoing echoes
  (wkc=0, data identical to sent).
- The exchange waits for a real processed response (wkc > 0) before
  completing.

## Actual Behavior Today

Correct after the echo filter fix. Both transport-level (`pkttype: :outgoing`)
and content-based echo filtering prevent echo frames from completing the
exchange prematurely.

## Test Shape

1. Boot redundant raw ring on veth pairs.
2. Warm up: verify single-datagram BRD succeeds.
3. Send `init_default_reset` BWR transaction (13 datagrams).
4. Assert all required BWR datagrams have wkc > 0.
5. Repeat multi-datagram BWR 10 times for timing confidence.
6. Also test with `drop_outgoing_echo?: false` to exercise the link-layer
   wkc=0 guard independently of transport-level filtering.

## Simulator API Notes

- Current API is enough.
- The simulator's veth pair naturally reproduces the echo race because
  AF_PACKET delivers outgoing copies with `pkttype: :outgoing`.
