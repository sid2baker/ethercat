# Missing Registers Helpers
## What it does
Tracks ESC register helpers needed by the reference-note translations that are not currently exposed by `EtherCAT.Slave.Registers`.

## Key sequence (IgH + SOEM consensus)
1. Keep call sites on `Registers.*` API, not hardcoded offsets.
2. Add missing helper(s) before implementing subsystem logic.
3. Use helper names that map 1:1 to protocol intent (sync cycle, assign activate, latch status/timestamps).

## Elixir translation
| Needed helper | Reason |
|---------------|--------|
| `Registers.dc_assign_activate/0,1` | Used by IgH DC assign stage and SOEM sync activation sequencing |
| `Registers.dc_sync1_cycle_time/0,1` | Required for SYNC0+SYNC1 programming parity |
| `Registers.dc_latch_event_status/0` | Required for latch event polling |
| `Registers.dc_latch0_pos_time/0` | LATCH0 positive-edge timestamp read/clear |
| `Registers.dc_latch0_neg_time/0` | LATCH0 negative-edge timestamp read/clear |
| `Registers.dc_latch1_pos_time/0` | LATCH1 positive-edge timestamp read/clear |
| `Registers.dc_latch1_neg_time/0` | LATCH1 negative-edge timestamp read/clear |

```elixir
# Generic register-flag extraction pattern (little-endian flag word)
<<flag0::1, flag1::1, _::14>> = <<flags::16-little>>
```

```elixir
Bus.transaction_queue(link, fn tx ->
  tx
  |> Transaction.fpwr(station, Registers.dc_sync0_cycle_time(sync0_ns))
  |> Transaction.fpwr(station, Registers.dc_assign_activate(assign_code))
end)
```

Suggested `gen_statem` integration points:
1. Master/DC setup path for `dc_assign_activate` and `dc_sync1_cycle_time`.
2. Slave `:op` poll path for latch status/timestamp helpers.

## Gotchas
- Do not add direct numeric offset tuples at call sites; extend `Registers` first.
- Keep helper pairs (`/0` read descriptor, `/1` encoded write) for write-capable registers.

## Read more
- `lib/ethercat/slave/registers.ex` — current helper coverage baseline
- `docs/references/notes/dc-sync.md` — sync-related missing helpers in context
- `docs/references/notes/dc-latch.md` — latch-related missing helpers in context
