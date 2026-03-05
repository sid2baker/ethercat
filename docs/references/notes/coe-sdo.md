# CoE SDO download/upload + mailbox
## What it does
Transfers CoE object dictionary entries over mailbox transport, including expedited and segmented SDO paths, with strict mailbox request/response matching.

## Key sequence (IgH + SOEM consensus)
1. Validate CoE mailbox support and mailbox sizes for request type.
2. Build SDO upload/download request header (index, subindex, command mode).
3. Send mailbox request and confirm transport-level success.
4. Poll mailbox status until response is available.
5. Fetch mailbox payload and validate protocol, command class, index/subindex.
6. Handle abort frames or segmented continuation (toggle tracking).

Differences:
1. IgH models this as explicit FSM states (`ec_fsm_coe_down_start` -> `..._down_response`, `ec_fsm_coe_up_start` -> `..._up_response`).
2. SOEM `ecx_SDOread`/`ecx_SDOwrite` is blocking procedural code around `ecx_mbxsend`/`ecx_mbxreceive` loops.
3. Ticket names `ec_SDOread`/`ec_SDOwrite` map to `ecx_SDOread`/`ecx_SDOwrite` in this snapshot.

## Elixir translation
| C pattern | Elixir equivalent |
|-----------|-------------------|
| Mailbox send then poll | `Bus.transaction_queue` write to mailbox window, then repeated `fprd` mailbox status checks |
| Validate CoE response header | Binary match mailbox payload before decode |
| Segmented SDO transfer | `gen_statem` loop with toggled segment flag in state data |

```elixir
# SDO command byte (little-endian bit order)
<<_reserved::1, size_indicated::1, expedited::1, _unused::2, ccs::3>> = <<cmd::8-little>>
```

```elixir
Bus.transaction_queue(link, fn tx ->
  tx
  |> Transaction.fpwr(station, {mailbox_rx_offset, coe_request_frame})
  |> Transaction.fprd(station, Registers.sm_status(1))
  |> Transaction.fprd(station, {mailbox_tx_offset, mailbox_tx_size})
end)
```

Suggested `gen_statem` names:
1. `:sdo_down_request`, `:sdo_down_wait`, `:sdo_down_response`.
2. `:sdo_up_request`, `:sdo_up_wait`, `:sdo_up_response`.
3. Internal events: `:mailbox_check`, `:segment_next`.

## Gotchas
- Mailbox counters are session identifiers; reuse/wrap mistakes can alias responses.
- Abort frames are protocol-valid responses and must be parsed before retry logic.
- Segment toggle handling is mandatory for multi-fragment SDO integrity.
- Mailbox offsets are runtime SII-derived values, not fixed register helpers.

## Read more
- `docs/references/igh/master/fsm_coe.c` — key functions: `ec_fsm_coe_down_start`, `ec_fsm_coe_down_response`, `ec_fsm_coe_up_start`, `ec_fsm_coe_up_response`
- `docs/references/soem/src/ec_coe.c` — key functions: `ecx_SDOwrite`, `ecx_SDOread`
