## Scenario

Multi-datagram BWR transactions in redundant mode must return wkc > 0 for
all processed registers, even when unchanged `wkc=0` passthrough copies can
arrive before the authoritative processed cross-delivery response.

## Real-World Analog

During master startup, `init_default_reset` sends 13 BWR datagrams in a
single frame to reset all slaves. In redundant mode, unchanged `wkc=0`
passthrough copies can show up before the authoritative processed response.
If the link accepts those copies as final, the caller sees all-zero WKC values
even though the ring later produces a real processed reply.

## Expected Master Behavior

- All required BWR datagrams return wkc > 0 (slaves processed them).
- Raw AF_PACKET transport suppresses local TX delivery with
  `PACKET_IGNORE_OUTGOING`.
- The redundant link still treats unchanged `wkc=0` copies as
  non-authoritative and waits for processed data.
- The exchange waits for a real processed response (wkc > 0) before
  completing.

## Actual Behavior Today

Correct. Kernel-level outgoing suppression plus the link's non-authoritative
copy handling prevent all-zero passthrough frames from completing the exchange
prematurely.

## Test Shape

1. Boot redundant raw ring on veth pairs.
2. Warm up: verify single-datagram BRD succeeds.
3. Send `init_default_reset` BWR transaction (13 datagrams).
4. Assert all required BWR datagrams have wkc > 0.
5. Repeat multi-datagram BWR 10 times for timing confidence.

## Simulator API Notes

- Current API is enough.
- The simulator's redundant raw topology still exercises the same completion
  rules around authoritative processed replies vs unchanged passthrough data.
