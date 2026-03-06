# DC: LATCH capture + event polling
## What it does
Captures hardware edge timestamps (LATCH0/LATCH1) against DC time and exposes them via poll/read semantics so application logic can consume deterministic external-event timing.

## Key sequence (IgH + SOEM consensus)
1. Enable DC sync/latch mode in slave DC configuration.
2. Poll latch event status register for pending edge flags.
3. For each asserted edge, read matching timestamp register.
4. Treat timestamp read as acknowledgement and continue polling.

Differences:
1. No dedicated latch state path is present in IgH `fsm_slave_config.c` in this snapshot (only DC sync cycle/start/assign path).
2. No `ec_dclatch0`/`ecx_dclatch0` symbol exists in SOEM `src/ec_dc.c` in this snapshot; only receive-time latch for propagation-delay calibration exists in `ecx_configdc`.
3. Implementation ticket should treat latch behavior as additive, not copied from a single canonical function in these versions.

## Elixir translation
| C pattern | Elixir equivalent |
|-----------|-------------------|
| Poll latch status register | `Bus.transaction(bus, Transaction.fprd(station, Registers.dc_latch_event_status()), deadline_us)` (helper missing today) |
| Read and clear timestamp source | `Transaction.fprd(tx, station, Registers.dc_latch0_pos_time())` etc. (helpers missing today) |
| Poll loop | Slave `gen_statem` `:op` + `{:state_timeout, :latch_poll}` event |

```elixir
# Event bits from 16-bit latch status (little-endian)
<<_::4, l0_pos::1, l0_neg::1, _::2, l1_pos::1, l1_neg::1, _::6>> = <<status::16-little>>
```

```elixir
Bus.transaction(
  bus,
  Transaction.new()
  |> Transaction.fprd(station, Registers.dc_latch_event_status())
  |> Transaction.fprd(station, Registers.dc_latch0_pos_time())
)
```

Suggested `gen_statem` names:
1. State: `:op`.
2. Event: `{:state_timeout, :latch_poll}`.
3. Internal dispatch: `:latch_event` with payload `{latch_id, edge, timestamp_ns}`.

## Gotchas
- Latch bits are edge-specific; read the matching timestamp register to clear the exact pending flag.
- Poll interval controls latency but not timestamp precision; hardware capture is independent of poll jitter.
- This repository currently lacks all latch register helpers; see `docs/references/notes/missing-registers.md`.

## Read more
- `docs/references/igh/master/fsm_slave_config.c` — key functions: `ec_fsm_slave_config_state_dc_cycle`, `ec_fsm_slave_config_state_dc_sync_check`, `ec_fsm_slave_config_state_dc_start`
- `docs/references/soem/src/ec_dc.c` — key function: `ecx_configdc` (receive-time latch only)
