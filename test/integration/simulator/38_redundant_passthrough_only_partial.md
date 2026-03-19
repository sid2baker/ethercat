## Scenario

Redundant bus discards passthrough-only replies (wkc=0, data unchanged)
when the processed cross-delivery is delayed beyond the frame timeout.

## Real-World Analog

In a healthy redundant ring, the reverse-path copy (secondary TX -> slaves ->
primary RX) arrives as a passthrough with wkc=0 because slaves already
processed the forward-path copy. If the forward-path response is delayed
(e.g. congestion, slow slave), only the passthrough arrives within the
timeout window.

## Expected Master Behavior

- The passthrough copy (wkc=0, data unchanged) is indistinguishable from an
  outgoing echo and is correctly discarded by the content-based echo filter.
- The exchange times out because the real processed response arrives too late.
- The bus returns `{:error, :timeout}` to the caller.

## Actual Behavior Today

Correct. The echo filter discards the passthrough and the timeout fires.

## Test Shape

1. Boot redundant raw ring on veth pairs.
2. Delay the forward-path response by 200ms at the simulator's secondary
   endpoint (only delays frames originating from primary ingress).
3. Issue a fixed-station `FPRD` to the right-most slave so the secondary-ingress
   copy is passthrough-only.
4. Assert that `Bus.transaction` returns `{:error, :timeout}`.

## Simulator API Notes

- Current API is enough (`Transport.Raw.inject_fault/1` with
  `RawFault.delay_response/2`).
