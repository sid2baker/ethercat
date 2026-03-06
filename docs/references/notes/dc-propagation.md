# DC: propagation delay + system time offset
## What it does
Aligns every DC-capable slave clock to a common EtherCAT epoch and writes per-slave line delay so distributed time is phase-consistent across the topology.

## Key sequence (IgH + SOEM consensus)
1. Discover DC-capable slaves and establish a reference clock.
2. Latch per-port receive timestamps, then read per-slave DC receive times.
3. Derive topology-relative propagation delay and accumulate parent-to-child delay.
4. Compute system-time offset from host/app time vs slave local DC time.
5. Write offset and delay back to each DC-capable slave.
6. Revisit offsets after elapsed time correction to reduce read/write latency error.

Differences:
1. IgH splits work across two phases: topology/delay calculation first (`ec_master_calc_dc`), then offset+delay writes during master FSM (`ec_fsm_master_enter_write_system_times` -> `ec_fsm_master_state_dc_read_offset` -> `ec_fsm_master_state_dc_write_offset`).
2. SOEM performs discovery, delay, and offset writes in one blocking pass (`ecx_configdc`).
3. Ticket names `ec_master_calc_dc_delays` / `ec_master_calc_dc_sync_times` are not present in this snapshot; equivalent behavior is distributed across the functions above.

## Elixir translation
| C pattern | Elixir equivalent |
|-----------|-------------------|
| Latch all DC receive times before per-slave reads | `Bus.transaction(bus, Transaction.bwr(Registers.dc_recv_time_latch()))` |
| Read receive-time + local DC time | `Transaction.fprd(tx, station, Registers.dc_recv_time(port))` and `Transaction.fprd(tx, station, Registers.dc_recv_time_ecat())` |
| Write computed offset + delay | `Transaction.fpwr(tx, station, Registers.dc_system_time_offset(offset_ns))` then `Transaction.fpwr(tx, station, Registers.dc_system_time_delay(delay_ns))` |
| Reset speed counter/PLL seed | `fprd` + same-value `fpwr` on `Registers.dc_speed_counter_start()` |

```elixir
# SOEM-style active-port mask extraction (PORTM0..PORTM3)
<<p0::1, p1::1, p2::1, p3::1, _::4>> = <<active_ports::8-little>>
```

```elixir
Bus.transaction(
  bus,
  Transaction.new()
  |> Transaction.fprd(ref_station, Registers.dc_recv_time_ecat())
  |> Transaction.fpwr(ref_station, Registers.dc_system_time_offset(offset_ns))
  |> Transaction.fpwr(ref_station, Registers.dc_system_time_delay(delay_ns))
)
```

Suggested `gen_statem` placement:
1. Master `:scanning` `{:timeout, :scan_poll}` handler computes delay/offset plan.
2. Master `:configuring` runs per-slave offset+delay writes before slave activation.

## Gotchas
- Offsets must be computed against EtherCAT epoch time, not Unix epoch.
- Delay and offset writes are order-sensitive: stale delay with fresh offset causes jitter spikes.
- `master->app_time`/host time must be available before offset correction; IgH defers otherwise.
- Missing helper inventory is centralized in `docs/references/notes/missing-registers.md`.

## Read more
- `docs/references/igh/master/fsm_master.c` — key functions: `ec_fsm_master_state_scan_slave`, `ec_fsm_master_enter_write_system_times`, `ec_fsm_master_state_dc_read_offset`, `ec_fsm_master_state_dc_write_offset`
- `docs/references/igh/master/master.c` — key functions: `ec_master_calc_dc`, `ec_master_calc_transmission_delays`
- `docs/references/soem/src/ec_dc.c` — key function: `ecx_configdc`
