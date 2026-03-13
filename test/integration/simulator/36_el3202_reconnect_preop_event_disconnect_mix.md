## Scenario

Use the captured `EL3202` fixture instead of a synthetic mailbox-only slave.
The RTD terminal disconnects, its reconnect-time PREOP rebuild drops the second
startup SDO reply (`0x8010:0x19`), and that retained PREOP fault later arms a
counted PDO disconnect on the digital outputs.

## Why

This is closer to the real hardware ring than the synthetic mailbox fixtures:

- the mailbox failure lands on a real captured startup SDO map
- the slave also participates in PDO input decode through `channel1` /
  `channel2`
- the follow-up disconnect still proves the master can recover cyclic traffic
  around the RTD terminal's retained PREOP fault

## Expectations

1. baseline EL3202 SDO config and typed RTD decode are healthy before faults
2. reconnect-time timeout on `0x8010:0x19` retains `:rtd` in `PREOP`
3. that retained RTD fault can arm a later counted `:outputs` disconnect
4. outputs recover first, but the master stays in `:recovering` because the
   RTD terminal still participates in the shared domain
5. a later RTD retry heals too, and both full-ring PDO flow and typed
   `read_input/2` resume
