# FMMU + SyncManager config write
## What it does
Binds logical process image regions to slave physical process RAM by programming SyncManagers first, then FMMUs that map those SM buffers into LRW space.

## Key sequence (IgH + SOEM consensus)
1. Clear or reset prior SM/FMMU state before applying new mapping.
2. Program mailbox SMs (when present), then PDO SMs with computed lengths/flags.
3. Derive FMMU entries from active PDO SM windows.
4. Write FMMU entries with direction-specific type and activation.
5. Proceed only after positive WKC checks.

Differences:
1. IgH batches SM pages/FMMU pages and validates each stage FSM state (`...state_pdo_sync`, `...state_fmmu`).
2. SOEM computes SM/FMMU layout from CoE/SII mapping, then writes each SM/FMMU entry iteratively (`ecx_map_sm`, `ecx_config_create_input_mappings`, `ecx_config_create_output_mappings`).
3. Ticket mention `ec_fsm_slave_config_state_sync`; in this snapshot the relevant states are `ec_fsm_slave_config_state_mbox_sync` and `ec_fsm_slave_config_state_pdo_sync`.

## Elixir translation
| C pattern | Elixir equivalent |
|-----------|-------------------|
| Program SM page | `Transaction.fpwr(tx, station, Registers.sm(index, sm_page_bin))` |
| Program FMMU page | `Transaction.fpwr(tx, station, Registers.fmmu(index, fmmu_page_bin))` |
| Stage-gated config | Slave `:preop` path: SM registration first, FMMU writes second |

```elixir
# SM status byte example
<<_::3, mailbox_full::1, last_buffer::2, _::2>> = <<sm_status::8-little>>
```

```elixir
Bus.transaction(
  bus,
  Transaction.new()
  |> Transaction.fpwr(station, Registers.sm(sm_index, sm_page))
  |> Transaction.fpwr(station, Registers.fmmu(fmmu_index, fmmu_page))
)
```

Suggested `gen_statem` names:
1. `:preop` enter executes `:configure_sm` then `:configure_fmmu` internal events.
2. Keep transition decisions in event handlers, not `:enter` callbacks.

## Gotchas
- FMMU write before SM enable can produce transient invalid mapping and AL errors.
- SM length zero requires explicit disable semantics; do not leave stale enable bits set.
- Byte-vs-bit mapping paths differ; mixed handling breaks compact digital I/O slaves.

## Read more
- `docs/references/igh/master/fsm_slave_config.c` — key functions: `ec_fsm_slave_config_enter_pdo_sync`, `ec_fsm_slave_config_state_pdo_sync`, `ec_fsm_slave_config_enter_fmmu`, `ec_fsm_slave_config_state_fmmu`
- `docs/references/soem/src/ec_config.c` — key functions: `ecx_map_sm`, `ecx_config_create_input_mappings`, `ecx_config_create_output_mappings`
