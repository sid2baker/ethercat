# SII EEPROM read state machine
## What it does
Performs reliable EEPROM/SII access through ESC command/status registers with busy/error polling, ownership handoff (PDI vs master), and retry timing.

## Key sequence (IgH + SOEM consensus)
1. Ensure EEPROM access is owned by master side.
2. Issue EEPROM read/write command with target word address.
3. Poll EEPROM status until busy clears or timeout expires.
4. Read/write EEPROM data payload and verify status/error bits.
5. Restore ownership (to PDI when required by caller flow).

Differences:
1. IgH is an explicit FSM (`ec_fsm_sii_state_start_reading` -> `..._read_check` -> `..._read_fetch`; analogous write states).
2. SOEM uses blocking helper loops (`ecx_eeprom_waitnotbusyFP/AP`, `ecx_readeepromFP/AP`, `ecx_readeeprom1/2`) plus ownership helpers (`ecx_eeprom2master`, `ecx_eeprom2pdi`).
3. IgH uses one datagram object across states; SOEM allocates operation structs and retries per low-level call.

## Elixir translation
| C pattern | Elixir equivalent |
|-----------|-------------------|
| Command + poll state machine | Slave internal events `:sii_start`, `:sii_poll`, `:sii_fetch` |
| Busy loop with timeout | `state_timeout`-driven retry loop storing `started_at_ms` in state data |
| Ownership handoff | Queue writes using `Registers.eeprom_ecat_access/0` and `Registers.eeprom_pdi_access/0` |

```elixir
# EEPROM status flags example (naming mirrors busy/error bits in C helpers)
<<busy::1, _::3, nack::1, _::2, r64::1, _::8>> = <<eep_status::16-little>>
```

```elixir
{eep_addr, _} = Registers.eeprom_address()
{eep_ctl, _} = Registers.eeprom_control()

Bus.transaction_queue(link, fn tx ->
  tx
  |> Transaction.fpwr(station, {eep_addr, <<word_addr::32-little>>})
  |> Transaction.fpwr(station, {eep_ctl, cmd_bin})
  |> Transaction.fprd(station, Registers.eeprom_control())
  |> Transaction.fprd(station, {Registers.eeprom_data(), data_width})
end)
```

Suggested `gen_statem` names:
1. `:sii_read_start`, `:sii_read_check`, `:sii_read_fetch`.
2. `:sii_write_start`, `:sii_write_check`.

## Gotchas
- EEPROM busy polling requires both transport success and status-bit clearance checks.
- Some devices need inhibit delay before write status becomes trustworthy (IgH `SII_INHIBIT`).
- Data width may be 4 or 8 bytes; choose `data_width` from status capability, not constants.

## Read more
- `docs/references/igh/master/fsm_sii.c` — key functions: `ec_fsm_sii_state_start_reading`, `ec_fsm_sii_state_read_check`, `ec_fsm_sii_state_read_fetch`, `ec_fsm_sii_state_start_writing`, `ec_fsm_sii_state_write_check2`
- `docs/references/soem/src/ec_main.c` — key functions: `ecx_eeprom2master`, `ecx_eeprom2pdi`, `ecx_eeprom_waitnotbusyFP`, `ecx_readeepromFP`, `ecx_readeeprom1`, `ecx_readeeprom2`
