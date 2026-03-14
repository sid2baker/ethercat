## Scenario

Keep the captured `EK1100 -> EL1809 -> EL2809 -> EL3202` ring shape, but move
the `EL3202` into its own PDO domain before forcing a reconnect-time PREOP
mailbox timeout on its startup SDO map.

## Why

Scenario `36` proved the shared-domain captured-device fault mix. The next
useful regression is the split-domain variant:

- the RTD terminal still uses the real captured startup SDO map
- the digital loopback stays on its own domain
- retained RTD PREOP rebuild faults should not falsely degrade unrelated
  loopback I/O

## Expectations

1. baseline digital loopback and typed RTD decode are healthy before faults
2. reconnect-time timeout on `0x8010:0x19` retains `:rtd` in `PREOP`
3. the digital loopback domain stays healthy and cyclic I/O continues while
   the RTD fault is retained
4. the RTD retry path eventually heals too, and typed RTD decode resumes

## Test Shape

1. boot the captured-device ring with digital I/O on `:main` and RTD signals on
   `:rtd`
2. seed RTD samples and assert baseline SDO reads plus typed decode
3. inject a counted `:rtd` disconnect window plus a reconnect-time dropped
   startup mailbox response for `0x8010:0x19`
4. assert the RTD fault is retained in `PREOP` while the `:main` loopback
   domain stays healthy
5. assert a later RTD retry clears the retained fault and typed RTD reads work
   again

## Simulator API Notes

Current simulator fault builders and helper surface are enough.

No API change needed.
