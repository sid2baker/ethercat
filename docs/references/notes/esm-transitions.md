# ESM transitions + state check polling
## What it does
Moves slaves through AL states (`INIT`/`PREOP`/`SAFEOP`/`OP`) and confirms target state with polling, including AL error-code handling and acknowledge flow.

## Key sequence (IgH + SOEM consensus)
1. Write requested AL control state.
2. Poll AL status until low-nibble matches requested state or timeout.
3. On mismatch/error, read AL status code and execute acknowledge path.
4. Continue polling until ACK error clears or fail timeout.

Differences:
1. IgH `fsm_slave_config` delegates transition mechanics to `ec_fsm_change_*` states (`start`, `check`, `status`, `code`, `ack`, `check_ack`).
2. SOEM centralizes polling in blocking `ecx_statecheck` (single loop, optional slave=0 aggregate behavior).
3. IgH explicitly handles spontaneous intermediate state changes; SOEM loop just returns final observed state.

## Elixir translation
| C pattern | Elixir equivalent |
|-----------|-------------------|
| AL control write | `Bus.transaction_queue(link, &Transaction.fpwr(&1, station, Registers.al_control(code)))` |
| AL status poll | retry loop with `Transaction.fprd(tx, station, Registers.al_status())` |
| AL error code fetch + ack | `fprd Registers.al_status_code()` then `fpwr Registers.al_control(current_state_with_ack)` |

```elixir
# AL status low nibble + ACK_ERR bit
<<state::4, ack_err::1, _::11>> = <<al_status::16-little>>
```

```elixir
Bus.transaction_queue(link, fn tx ->
  tx
  |> Transaction.fpwr(station, Registers.al_control(target_code))
  |> Transaction.fprd(station, Registers.al_status())
  |> Transaction.fprd(station, Registers.al_status_code())
end)
```

Suggested `gen_statem` names:
1. States: `:init`, `:preop`, `:safeop`, `:op`.
2. Transition event: `{:call, {:request, target_state}}`.
3. Poll events: `{:state_timeout, :al_status_poll}` and `{:internal, :ack_error}`.

## Gotchas
- `ACK_ERR` handling must preserve current-state nibble while adding acknowledge bit.
- Aggregate-all-slaves polling semantics (SOEM slave `0`) can hide per-slave divergence.
- Enter callbacks must not transition state; transition decisions belong in explicit events.

## Read more
- `docs/references/igh/master/fsm_slave_config.c` — key functions: `ec_fsm_slave_config_enter_safeop`, `ec_fsm_slave_config_state_safeop`, `ec_fsm_slave_config_enter_op`, `ec_fsm_slave_config_state_op`
- `docs/references/igh/master/fsm_change.c` — key functions: `ec_fsm_change_start`, `ec_fsm_change_state_status`, `ec_fsm_change_state_code`, `ec_fsm_change_state_ack`, `ec_fsm_change_state_check_ack`
- `docs/references/soem/src/ec_main.c` — key function: `ecx_statecheck`
