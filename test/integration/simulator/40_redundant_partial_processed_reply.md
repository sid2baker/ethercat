## Scenario

Redundant bus accepts a degraded processed reply when the redundant copy
from the opposite direction is delayed beyond the merge window.

## Real-World Analog

In a redundant ring, one path may be consistently slower than the other
(asymmetric cable lengths, different slave counts per segment, or
congestion). The fast path delivers a fully processed response while the
slow path's copy arrives after the merge window expires.

## Expected Master Behavior

- The first processed reply (wkc > 0) completes the exchange immediately
  if classified as a forward cross, or after the merge window for other
  classifications.
- The bus returns `{:ok, results}` with valid wkc to the caller.
- Bus info reports `type: :redundant`.

## Actual Behavior Today

Correct. The exchange completes on the first processed arrival.

## Test Shape

1. Boot redundant raw ring on veth pairs.
2. Warm up: verify BRD succeeds with wkc > 0.
3. Delay responses from primary endpoint for secondary-ingress frames by
   200ms (simulating a slow reverse path).
4. Assert `Bus.transaction(BRD)` returns `{:ok, [%{wkc: wkc}]}` with wkc > 0.
5. Assert bus info shows `type: :redundant`.

## Simulator API Notes

- Current API is enough (`RawSocket.set_response_delay/3`).
