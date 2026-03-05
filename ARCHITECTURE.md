# EtherCAT — Architecture

## What This Is

A pure-Elixir EtherCAT master library. No NIF. No kernel module. Raw sockets only.
Targets automation workloads (discrete I/O, drives) where 1–10 ms cycle times are
sufficient and BEAM's scheduler jitter is compensated by the distributed clock layer.

---

## Module Map

```
EtherCAT.Application
│
├── EtherCAT.Master              (singleton gen_statem — bus lifecycle coordinator)
│
├── EtherCAT.SessionSupervisor   (dynamic supervisor for session-scoped runtime processes)
│   ├── EtherCAT.Bus             (raw socket server — all frame I/O goes here)
│   ├── EtherCAT.DC              (gen_statem — periodic ARMW drift ticker)
│   └── EtherCAT.Domain          (gen_statem per domain — cyclic LRW exchange)
│
├── EtherCAT.SlaveSupervisor     (simple_one_for_one — :temporary slaves)
│   └── EtherCAT.Slave           (gen_statem per named slave — ESM lifecycle)
│       ├── EtherCAT.SII         (EEPROM reader — stateless, called from Slave.init)
│       ├── EtherCAT.Slave.Driver (behaviour contract for user drivers)
│       └── EtherCAT.Slave.Registers (ESC register address map — pure functions)
```

Registry: `EtherCAT.Registry` (local). Slaves register as `{:slave, name}` and
`{:slave_station, station}`; Domains register as `{:domain, id}`.

---

## Data Flow

### Startup (Master coordinates)

```
Master :scanning ──── BRD 0x0000, count stable ──── Master :configuring
  │
  ├── APWR 0x0010 × N        assign station addresses
  ├── DC.initialize_clocks/2 propagation delay calc + system time offset
  ├── SessionSupervisor      start Domain gen_stams (must exist before slaves)
  └── SlaveSupervisor        start Slave gen_stams (each auto-advances to PreOp)
        │
        Slave :init ─── SII read ─── configure mailbox SMs ─── AL 0x02 ─── Slave :preop
              │
              preop enter: sdo_config → register_pdos_and_fmmus → {:slave_ready, name, :preop}
              │
              Master collects all {:slave_ready} →
              (explicit config) DC start → domain cycling → SafeOp → Op
              OR (dynamic startup) remain in PreOp for runtime configuration →
              Master :running
```

### Cyclic I/O (Domain owns)

```
Domain :cycling
  state_timeout :tick every period_ms
    build_frame  → splice outputs from ETS into zero-filled binary (iodata, no alloc)
    Bus.transaction LRW → raw socket send → receive → response binary
    dispatch_inputs → compare each slice against ETS → on change:
      ETS update + send {:domain_input, domain_id, key, raw} to slave pid
      Slave decodes via driver.decode_inputs/3 → notify subscribers
```

### Output path (application → bus)

```
Application
  Domain.write(domain_id, {slave, pdo}, binary)  ← direct :ets.update_element — no gen_statem
  next Domain LRW tick picks up the new value and writes it to the slave
```

---

## Key Design Decisions

### Bus as single serialization point

All frame I/O goes through `EtherCAT.Bus`. The bus has two entry points:
- `Bus.transaction/2` — direct, blocking. Used by DC tick and Domain cycle where
  ordering relative to other ops matters.
- `Bus.transaction_queue/2` — queues datagrams into the next frame send. Used during
  slave init (register writes) to batch multiple FPWR ops without per-write round-trips.

This prevents multiple gen_stams from racing on the socket.

### ETS hot path for I/O

Domain I/O bypasses the gen_statem entirely. The ETS table for each domain is `:public`
with `read_concurrency: true` / `write_concurrency: true`. Any process can read current
input values or write output values directly without a message round-trip.

### Jitter compensation via DC

BEAM's scheduler has sub-millisecond jitter. The Distributed Clock layer compensates:
ESC clocks are synchronized to sub-microsecond precision by the `DC` gen_statem, which
sends a periodic ARMW to the reference slave's system time register. All slaves lock their
local clock to this via a PLL. SYNC0 pulses fire from the hardware clock, not the software
scheduler — PDO exchange timing is hardware-anchored regardless of BEAM scheduling.

### gen_statem + :state_enter throughout

All gen_stams use `[:handle_event_function, :state_enter]`. Enter callbacks arm recurring
timers (domain tick, DC tick, latch poll) and emit telemetry. No enter callback may
transition state (illegal in OTP). State-deciding logic lives in the event handler that
calls `{:next_state, ...}`.

---

## Startup Sequence Detail

1. `Bus.open_link/1` — opens raw Ethernet socket on named interface
2. `DC.initialize_clocks/2` — BWR latch, read receive times, compute propagation delays, write offsets
3. `Domain.start_link` per config — creates ETS tables, enters `:open`
4. `Slave.start_link` per config — starts SII read, mailbox SM config, auto-advances to `:preop`
5. `Master` waits for all `{:slave_ready, name, :preop}` messages (30 s timeout)
6. If activatable slaves exist: `DC.start_link` — starts ARMW ticker (after all slaves are in PreOp)
7. If activatable slaves exist: `Domain.start_cycling` per domain — begins self-timed LRW
8. If activatable slaves exist: `Slave.request(:safeop)` per slave — configures DC SYNC signals (SYNC0 activation)
9. If activatable slaves exist: `Slave.request(:op)` per slave — full process data exchange active

---

## Frame Budget (100 µs / 1 kHz example)

| Phase | Time |
|-------|------|
| BEAM scheduler + send syscall | ~50–200 µs (variable, dominant) |
| Wire propagation (10 slaves × 100 ns/hop + cable) | ~5–10 µs |
| ESC processing delay per slave | ~1 µs |
| LRW datagram overhead | ~2 µs |

At 1 ms cycle, the BEAM scheduler jitter is ~10–20% of the period. DC hardware clocks
absorb this jitter at the slave application layer — the SYNC0 pulse fires on schedule
even if the LRW frame arrives early or late.

---

## Component Context Files

Each subsystem has a co-located agent context file:

| File | Component |
|------|-----------|
| `lib/ethercat/slave.md` | Slave gen_statem — ESM lifecycle, driver behaviour, PDO registration |
| `lib/ethercat/master.md` | Master gen_statem — scanning, DC init, activation sequence |
| `lib/ethercat/domain.md` | Domain gen_statem — cyclic LRW, ETS schema, frame assembly |
| `docs/references/ethercat-esc-technology.md` | ESC hardware: FMMU, SM, DC, ESM, SII, interrupts |
| `docs/references/ethercat-esc-registers.md` | Full ESC register map (auto-extracted from datasheet) |
