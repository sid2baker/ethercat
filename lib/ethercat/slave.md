# EtherCAT.Slave — Agent Context Briefing

## Purpose

`EtherCAT.Slave` is a `gen_statem` (`:handle_event_function` + `:state_enter` mode) that
manages the EtherCAT State Machine (ESM) lifecycle for one physical slave device.

One Slave process per named slave. Registered in `EtherCAT.Registry` under two keys:
- `{:slave, name}` — atom name, used by public API
- `{:slave_station, station}` — integer station address, used for internal lookup

The Slave is supervised under `EtherCAT.SlaveSupervisor` as `:temporary` (not restarted on crash).

---

## ESM States and Transitions

```
:init → :preop  (auto, on startup)
:preop → :safeop → :op  (master-driven via Slave.request/2)
any → :init | :preop | :safeop  (backward transitions, master-driven)
:init ↔ :bootstrap  (optional, not commonly used)
```

AL state codes written to ESC register `0x0120`:
- `:init` = `0x01`
- `:preop` = `0x02`
- `:bootstrap` = `0x03`
- `:safeop` = `0x04`
- `:op` = `0x08`

Multi-step transitions (e.g., `:init` → `:op`) walk through intermediate states automatically
via the `@paths` map. `walk_path/2` calls `do_transition/2` for each intermediate state.

### State Entry Actions

**`:init` enter**: no-op. The init callback calls `do_auto_advance/1` immediately.

**Auto-advance (`:init` → `:preop`):**
1. Read SII EEPROM (identity, mailbox config, SM configs, PDO configs).
2. Configure mailbox SMs (SM0 recv + SM1 send) while still in INIT.
3. Write `0x02` to AL control (`0x0120`) and poll AL status (`0x0130`) until state matches or error bit set.
4. If success: transition to `:preop`. If failure: schedule retry after 200 ms via `{:timeout, :auto_advance}`.

**`:preop` enter** (synchronous, blocks until complete):
1. `invoke_driver(data, :on_preop)` — optional driver callback.
2. `run_sdo_config/1` — if driver exports `sdo_config/1`, execute each `{index, subindex, value, size}` as CoE expedited SDO download.
3. `register_pdos_and_fmmus/1` — resolve PDO names from SII, register with Domain, write SM+FMMU registers.
4. Send `{:slave_ready, name, :preop}` to `EtherCAT.Master`.

**`:safeop` enter**:
1. `invoke_driver(data, :on_safeop)`.
2. `configure_dc_signals/1` — if `dc_cycle_ns` is set and driver exports `dc_config/1`: write SYNC0/SYNC1 parameters, latch controls, start time, and activation byte in one frame.

**`:op` enter**:
1. `invoke_driver(data, :on_op)`.
2. If latches are configured, arm a recurring `state_timeout` poll (`:latch_poll`) to read latch event status/timestamps.

### Transition Mechanics

`do_transition/2`:
1. FPWR to `Registers.al_control(code)` — write requested state.
2. Poll `Registers.al_status()` up to 200 times at 1 ms intervals.
3. If status `[4]` (error bit) is set: read `0x0134` (error code), write `(current_state | 0x10)` to AL control to acknowledge, return `{:error, {:al_error, code}, data}`.

---

## Struct Fields

```elixir
%EtherCAT.Slave{
  link:              pid(),              # Bus server reference
  station:           non_neg_integer(),  # Configured station address (e.g. 0x1000)
  name:              atom(),             # Slave name atom
  driver:            module(),           # Module implementing EtherCAT.Slave.Driver (default: EtherCAT.Slave.Driver.Default)
  config:            map(),              # Driver-specific config, passed to all callbacks
  domain:            atom() | nil,       # Default domain id for auto-PDO-registration
  error_code:        non_neg_integer() | nil,  # Last AL status code from ESC
  identity:          map() | nil,        # vendor_id, product_code, revision, serial from SII
  mailbox_config:    map() | nil,        # recv_offset, recv_size, send_offset, send_size
  dc_cycle_ns:       pos_integer() | nil, # SYNC0 cycle time; nil disables DC
  sii_sm_configs:    list(),             # [{sm_index, phys_start, length, ctrl}] from SII
  sii_pdo_configs:   list(),             # [%{index, direction, sm_index, bit_size, bit_offset}]
  pdos:              list(),             # [{pdo_name, domain_id}] to register
  active_latches:    list() | nil,       # [{0|1, :pos|:neg}] from dc_config
  latch_poll_ms:     pos_integer() | nil, # latch poll interval while in :op
  pdo_registrations: map(),             # %{pdo_name => %{domain_id, sm_key, bit_offset, bit_size}}
  pdo_subscriptions: map(),             # %{pdo_name => [pid]}
  latch_subscriptions: map(),           # %{{latch_id, edge} => [pid]}
}
```

---

## Driver Behaviour Contract (`EtherCAT.Slave.Driver`)

All callbacks receive `(config :: map())` or `(slave_name :: atom(), config :: map())`.

| Callback | Required | Signature | Description |
|----------|----------|-----------|-------------|
| `process_data_profile/1` | yes | `config -> %{pdo_name => sii_index}` | Map of PDO names to SII PDO object indices (e.g. `0x1A00`). Used to resolve SM assignment and bit offsets from SII categories. |
| `encode_outputs/3` | yes | `(pdo_name, config, value) -> binary` | Encode application value to raw output bytes. Return `<<>>` for input-only PDOs. |
| `decode_inputs/3` | yes | `(pdo_name, config, binary) -> term` | Decode raw input bytes to application value. Return `nil` for output-only PDOs. |
| `on_preop/2` | optional | `(name, config) -> :ok` | Called on PreOp entry. |
| `on_safeop/2` | optional | `(name, config) -> :ok` | Called on SafeOp entry. |
| `on_op/2` | optional | `(name, config) -> :ok` | Called on Op entry. |
| `sdo_config/1` | optional | `config -> [{index, subindex, value, size}]` | SDO writes to execute in PreOp before SM/FMMU config. Can perform PDO remapping (0x1C12/0x1C13). |
| `dc_config/1` | optional | `config -> %{sync0_pulse_ns: pos_integer(), optional(:sync1_cycle_ns) => pos_integer(), optional(:latches) => [%{latch_id: 0\|1, edge: :pos\|:neg}]} \| nil` | DC signal parameters. Return `nil` to disable DC config on this slave. |
| `on_latch/5` | optional | `(name, config, latch_id, edge, timestamp_ns) -> :ok` | Called when a configured ESC LATCH event is captured during `:op`. |

Sub-byte PDOs (e.g., 1-bit digital channels): `decode_inputs` receives a 1-byte binary with the value in bit 0 (LSB). `encode_outputs` must return a 1-byte binary with the value in bit 0.

---

## PDO Registration Mechanics

Called from `:preop` enter in `register_pdos_and_fmmus/1`:

1. Resolve each `{pdo_name, domain_id}` from `data.pdos` to a SII PDO config entry via `process_data_profile/1` → SII index → match in `sii_pdo_configs`.
2. Group resolved PDOs by SM index (`sii_pdo_config.sm_index`).
3. For each SM group:
   a. Look up SM physical address and control byte from `sii_sm_configs`.
   b. Compute total SM byte size from all SII PDOs on that SM (not just driver-requested ones).
   c. Call `Domain.register_pdo(domain_id, {name, {:sm, sm_idx}}, total_sm_size, direction)` → `{:ok, logical_offset}`.
   d. FPWR SM register: 8 bytes encoding phys_start, size, ctrl, enable=`0x01`.
   e. FPWR FMMU register: 16 bytes encoding logical_offset, size, start_bit=0, stop_bit=7, phys_start, phys_start_bit=0, type=`0x01`(input)/`0x02`(output), activate=`0x01`.
   f. Store `%{domain_id, sm_key, bit_offset, bit_size}` per PDO name in `pdo_registrations`.

The domain key is `{slave_name, {:sm, sm_idx}}` — a single ETS entry covers all PDOs sharing an SM.

---

## DC Implementation — Current State

### What is implemented

SYNC0 + optional SYNC1 and LATCH0/1 polling. Configured at `:safeop` entry in `configure_dc_signals/1`:

1. Read `dc_config/1` from driver.
2. Compute `start_time = System.os_time(:nanosecond) - @ethercat_epoch_offset_ns + 100_000` (100 µs headroom for frame round-trip per §9.2.3.6 step 6).
3. Send FPWR datagrams in one frame:
   - `Registers.dc_sync0_cycle_time(cycle_ns)` → `0x09A0`
   - `Registers.dc_sync1_cycle_time(sync1_cycle_ns)` → `0x09A4`
   - `Registers.dc_pulse_length(pulse_ns)` → `0x0982`
   - `Registers.dc_sync0_start_time(start_time)` → `0x0990`
   - `Registers.dc_latch0_control(latch0_ctrl)` / `dc_latch1_control(latch1_ctrl)` → `0x09A8/0x09A9`
   - `Registers.dc_activation(0x03 | 0x07)` → `0x0981` (bits 0+1 always; bit2 when SYNC1 enabled)
4. In `:op`, if latches are configured, poll `0x09AE/0x09AF`; on captured edge read `0x09B0..0x09CF`, dispatch `{:slave_latch, ...}`, and call optional `on_latch/5`.

All writes happen in one frame so the activation datagram sees already-written parameters.

EtherCAT epoch offset: `946_684_800_000_000_000` ns (difference between Unix epoch 1970 and EtherCAT epoch 2000-01-01).

### What is missing

- **CoE sync mode objects**: `0x1C32` (output sync parameters) and `0x1C33` (input sync parameters). These CoE objects configure the slave application's synchronization mode (free-run, SM event, SYNC0). Required for drives and other servo devices. Currently no support for reading or writing these.
- **DC lock detection**: should poll `0x092C–0x092F` (system time difference) and wait for lock before entering Op.
- **SYNC0 status acknowledgement**: in acknowledge pulse mode (`pulse_ns=0`), slave application must read `0x098E` to release each SYNC0 pulse.

---

## Key Design Decisions

**Why `configure_dc_signals` at `:safeop` entry, not `:preop`?**
ETG.1020 §6.3.2 requires DC SYNC configuration after the slave has confirmed SafeOp. At this point FMMUs are already written (done in `:preop`) and the PDI is armed. Configuring earlier risks a race where the first SYNC0 pulse fires before the slave PDI is ready.

**Which bus transaction mode is used where?**
Configuration and mailbox writes use `Bus.transaction_queue/2` because delivery matters more than strict timing.
Runtime latch polling in `:op` uses `Bus.transaction/3` with a timeout budget slightly below poll/cycle period so stale polls are dropped instead of queued, preventing recurring latch polls from building backlog on the bus.

**Why send `{:slave_ready, name, :preop}` to `EtherCAT.Master`?**
Master waits for all named slaves to report `:preop` before advancing any slave to SafeOp/Op. This ensures all FMMUs and SM registers are written before the first LRW cycle starts. The master uses `Process.send(__MODULE__, ...)` so it doesn't need the slave's pid.

---

## Terminology Note

**ESC LATCH0/LATCH1 (hardware)**: physical input pins on the ESC chip. When asserted, the DC latch unit records the system timestamp. Registers at `0x09B0–0x09CF`. Used for precise external event timestamping.

**CoE "Input Latch" (0x1C33)**: CoE object dictionary entry that configures *when* the slave application samples PDO inputs relative to the SYNC0 event. Unrelated to the LATCH hardware pins. This object is not yet read or written by this codebase.

---

## Known Gaps and TODOs

- No CoE sync mode configuration (0x1C32/0x1C33); required for servo drives.
- No DC lock detection before advancing to Op.
- No per-slave health monitoring (AL status polling, error counter reads) after reaching Op.
- No IRQ-based input change detection; relying on cyclic LRW from Domain.
- SDO config failures are logged as warnings but do not prevent state advancement; could mask misconfiguration.
- No over-sampling support (multiple input samples per SYNC0 period).
