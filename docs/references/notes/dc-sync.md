# DC: SYNC0/SYNC1 activation + cycle time
## What it does
Programs periodic DC sync signal generation per slave and aligns first trigger time to the shared DC timeline.

## Key sequence (IgH + SOEM consensus)
1. Disable/clear current sync activation before reprogramming.
2. Program SYNC cycle registers (SYNC0 always, SYNC1 when enabled).
3. Read current slave DC time and compute future-aligned start time with shift.
4. Optionally poll synchronization quality before arming start.
5. Write start time, then activate sync output bits.

Differences:
1. IgH path is staged FSM: `ec_fsm_slave_config_enter_dc_cycle` -> `ec_fsm_slave_config_state_dc_cycle` -> `ec_fsm_slave_config_state_dc_sync_check` -> `ec_fsm_slave_config_state_dc_start` -> `ec_fsm_slave_config_state_dc_assign`.
2. SOEM `ecx_dcsync0`/`ecx_dcsync01` computes start from local time + fixed lead (`SyncDelay`) and writes immediately; no explicit sync-diff polling loop.
3. Public names in ticket (`ec_dcsync0`, `ec_dcsync01`) map to `ecx_dcsync0`, `ecx_dcsync01` in this snapshot.

## Elixir translation
| C pattern | Elixir equivalent |
|-----------|-------------------|
| Write cycle parameters before activation | Build one reliable `Transaction` with `Registers.dc_sync0_cycle_time/1` and missing helper `Registers.dc_sync1_cycle_time/1` |
| Check sync quality before start | `Transaction.fprd(tx, station, Registers.dc_system_time_diff())` with retry loop in `gen_statem` event handler |
| Start-time arm then assign/activate | `Transaction.fpwr(tx, station, Registers.dc_sync0_start_time(start_ns))` followed by missing helper `Registers.dc_assign_activate(code)` |

```elixir
# Absolute sync difference from DC system time diff register
<<_::1, abs_sync_diff::31>> = <<diff_raw::32-little>>
```

```elixir
Bus.transaction(
  bus,
  Transaction.new()
  |> Transaction.fpwr(station, Registers.dc_sync0_cycle_time(sync0_ns))
  |> Transaction.fpwr(station, Registers.dc_sync0_start_time(start_ns))
  |> Transaction.fpwr(station, Registers.dc_activation(activation_code))
)
```

Suggested `gen_statem` names:
1. Slave `:safeop` enter side-effect only; transition decisions in explicit events like `{:internal, :dc_sync_program}`.
2. Internal events: `:dc_sync_check`, `:dc_sync_start`, `:dc_sync_activate`.

## Gotchas
- Activation must be written last in the same transaction as the final parameters.
- SYNC1 in both stacks is derived from SYNC0 timing, not an independent clock source.
- Register helpers currently missing for full parity: `dc_sync1_cycle_time`, `dc_assign_activate`.
- See `docs/references/notes/missing-registers.md` for exact helper list.

## Read more
- `docs/references/igh/master/fsm_slave_config.c` — key functions: `ec_fsm_slave_config_enter_dc_cycle`, `ec_fsm_slave_config_state_dc_cycle`, `ec_fsm_slave_config_state_dc_sync_check`, `ec_fsm_slave_config_state_dc_start`, `ec_fsm_slave_config_state_dc_assign`
- `docs/references/soem/src/ec_dc.c` — key functions: `ecx_dcsync0`, `ecx_dcsync01`
