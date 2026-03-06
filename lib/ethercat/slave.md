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

**`:init` enter**: no-op. The init callback starts `initialize_to_preop/1` immediately.

**`:preop` enter**: no-op. PREOP-local configuration is triggered by explicit post-transition logic, not by the enter callback, so the state machine stays within OTP's `:state_enter` rules.

**`:safeop` enter**: no-op. SAFEOP-local DC signal programming is likewise driven by explicit post-transition logic after the AL transition has completed successfully.

**Auto-advance (`:init` → `:preop`):**
1. Read SII EEPROM (identity, mailbox config, SM configs, PDO configs).
2. Configure mailbox SMs (SM0 recv + SM1 send) while still in INIT, and require every configured-station write to acknowledge with `WKC = 1`.
3. Write `0x02` to AL control (`0x0120`) and poll AL status (`0x0130`) until the slave reports `PREOP` with the AL error bit clear.
4. If success: transition to `:preop` and run the PREOP-local configuration step.
5. If failure at any point: schedule retry after 200 ms via `{:timeout, :auto_advance}`.

**Post-`PREOP` configuration step** (runs immediately after the transition succeeds):
1. `invoke_driver(data, :on_preop)` — optional driver callback.
2. `run_mailbox_config/1` — if driver exports `mailbox_config/1`, execute each
   `{:sdo_download, index, subindex, binary}` mailbox step in order, using
   expedited or segmented CoE transfer as needed.
3. `configure_preop_process_data/1` — resolve the configured `process_data` request, register each SM group with its Domain, then write process-data SyncManagers and FMMUs.
4. Send `{:slave_ready, name, :preop}` to `EtherCAT.Master`.

**Post-`SAFEOP` configuration step** (runs immediately after the transition succeeds):
1. `invoke_driver(data, :on_safeop)`.
2. `configure_dc_signals/1` — if `dc_cycle_ns` is set and driver exports `distributed_clocks/1`: write SYNC0/SYNC1 parameters, latch controls, start time, and activation byte in one frame, and require every configured-station write to acknowledge with `WKC = 1`.

**`:op` enter**:
1. `invoke_driver(data, :on_op)`.
2. If latches are configured, arm a recurring `state_timeout` poll (`:latch_poll`) to read latch event status/timestamps.

### Transition Mechanics

`do_transition/2`:
1. FPWR to `Registers.al_control(code)` — write requested state.
2. Poll `Registers.al_status()` up to 200 times at 1 ms intervals.
3. If status `[4]` (error bit) is set: read `0x0134` (error code), write `(current_state | 0x10)` to AL control to acknowledge, and return either:
   - `{:error, {:al_error, code}, data}` if the acknowledge write succeeds
   - `{:error, {:al_error, code, {:ack_failed, reason}}, data}` if the acknowledge write itself fails

---

## Struct Fields

```elixir
%EtherCAT.Slave{
  bus:               pid(),              # Bus server reference
  station:           non_neg_integer(),  # Configured station address (e.g. 0x1000)
  name:              atom(),             # Slave name atom
  driver:            module(),           # Module implementing EtherCAT.Slave.Driver (default: EtherCAT.Slave.Driver.Default)
  config:            map(),              # Driver-specific config, passed to all callbacks
  error_code:        non_neg_integer() | nil,  # Last AL status code from ESC
  configuration_error: term() | nil,     # PREOP-local process-data configuration failure
  identity:          map() | nil,        # vendor_id, product_code, revision, serial from SII
  mailbox_config:    map() | nil,        # recv_offset, recv_size, send_offset, send_size
  mailbox_counter:   0..7,               # last used mailbox session counter for CoE traffic
  dc_cycle_ns:       pos_integer() | nil, # SYNC0 cycle time; nil disables DC
  sii_sm_configs:    list(),             # [{sm_index, phys_start, length, ctrl}] from SII
  sii_pdo_configs:   list(),             # [%{index, direction, sm_index, bit_size, bit_offset}]
  process_data_request: :none | {:all, atom()} | [{atom(), atom()}],
  active_latches:    list() | nil,       # [{0|1, :pos|:neg}] from distributed_clocks
  latch_poll_ms:     pos_integer() | nil, # latch poll interval while in :op
  signal_registrations: map(),          # %{signal_name => %{domain_id, sm_key, bit_offset, bit_size}}
  signal_registrations_by_sm: map(),    # %{sm_key => [{signal_name, %{bit_offset, bit_size}}]}
  input_subscriptions: map(),           # %{signal_name => MapSet.t(pid())}
  subscriber_refs:    map(),            # %{pid => monitor_ref}
  latch_subscriptions: map(),           # %{{latch_id, edge} => MapSet.t(pid())}
}
```

---

## Driver Behaviour Contract (`EtherCAT.Slave.Driver`)

All callbacks receive `(config :: map())` or `(slave_name :: atom(), config :: map())`.

| Callback | Required | Signature | Description |
|----------|----------|-----------|-------------|
| `process_data_model/1` | yes | `config -> %{signal_name => pdo_index \| %ProcessDataSignal{}}` | Map of logical signal names to either a whole PDO index or a bit-range inside a PDO. Used to resolve SM assignment and bit offsets from SII categories. |
| `encode_signal/3` | yes | `(signal_name, config, value) -> binary` | Encode one logical output signal to raw bytes. Return `<<>>` for input-only signals. |
| `decode_signal/3` | yes | `(signal_name, config, binary) -> term` | Decode one logical input signal from raw bytes. Return `nil` for output-only signals. |
| `on_preop/2` | optional | `(name, config) -> :ok` | Called on PreOp entry. |
| `on_safeop/2` | optional | `(name, config) -> :ok` | Called on SafeOp entry. |
| `on_op/2` | optional | `(name, config) -> :ok` | Called on Op entry. |
| `mailbox_config/1` | optional | `config -> [{:sdo_download, index, subindex, binary}]` | PREOP mailbox configuration steps. Used for CoE parameterization and PDO remapping before SM/FMMU config. `binary` may be any non-empty size; the runtime chooses expedited or segmented CoE transfer automatically. |
| `distributed_clocks/1` | optional | `config -> %{sync0_pulse_ns: pos_integer(), optional(:sync1_cycle_ns) => pos_integer(), optional(:latches) => [%{latch_id: 0\|1, edge: :pos\|:neg}]} \| nil` | DC signal parameters. Return `nil` to disable DC config on this slave. |
| `on_latch/5` | optional | `(name, config, latch_id, edge, timestamp_ns) -> :ok` | Called when a configured ESC LATCH event is captured during `:op`. |

Sub-byte signals (e.g., 1-bit digital channels): `decode_signal` receives a 1-byte binary with the value in bit 0 (LSB). `encode_signal` must return a 1-byte binary with the value in bit 0.

`ProcessDataSignal` may expose one field inside a larger PDO:

```elixir
%{
  status_word: EtherCAT.Slave.ProcessDataSignal.slice(0x1A00, 0, 16),
  actual_position: EtherCAT.Slave.ProcessDataSignal.slice(0x1A00, 16, 32)
}
```

---

## Process Data Configuration

Called from the explicit post-`PREOP` configuration step in `configure_preop_process_data/1`:

1. Normalize `data.process_data_request`:
   - `:none`
   - `{:all, domain_id}`
   - `[{signal_name, domain_id}]`
2. Resolve each `{signal_name, domain_id}` to a signal declaration via `process_data_model/1`.
3. Resolve that declaration to a SII PDO config entry via the declared PDO index.
4. If the declaration is a slice, add its bit offset inside the PDO to the PDO's bit offset inside the SyncManager.
5. Group resolved signals by SM index (`sii_pdo_config.sm_index`).
6. For each SM group:
   a. Look up SM physical address and control byte from `sii_sm_configs`.
   b. Compute total SM byte size from all SII PDOs on that SM (not just driver-requested ones).
   c. Call `Domain.register_pdo(domain_id, {name, {:sm, sm_idx}}, total_sm_size, direction)` → `{:ok, logical_offset}`.
   d. FPWR SM register: 8 bytes encoding phys_start, size, ctrl.
   e. FPWR FMMU register: 16 bytes encoding logical_offset, size, start_bit=0, stop_bit=7, phys_start, phys_start_bit=0, type=`0x01`(input)/`0x02`(output), activate=`0x01`.
   f. FPWR SM activate register with `0x01`.
   g. Store `%{domain_id, sm_key, bit_offset, bit_size}` per signal name in `signal_registrations`.
7. Reject any request that tries to place signals from the same SyncManager into multiple domains; this runtime maps one SM to one domain/FMMU span.
8. Build a second registration index keyed by `sm_key` so runtime domain-input dispatch can decode only the signals that actually belong to the changed SyncManager instead of scanning every registered signal on each domain update.
9. If PREOP-local mailbox or process-data configuration fails, `configuration_error` is set and later `SAFEOP/OP` requests are rejected locally.

The domain key is `{slave_name, {:sm, sm_idx}}` — a single ETS entry covers all signals sharing an SM.

---

## DC Implementation — Current State

### What is implemented

SYNC0 + optional SYNC1 and LATCH0/1 polling. Configured immediately after the
slave reaches `:safeop` in `configure_dc_signals/1`:

1. Read `distributed_clocks/1` from driver.
2. Compute `start_time = System.os_time(:nanosecond) - @ethercat_epoch_offset_ns + 100_000` (100 µs headroom for frame round-trip per §9.2.3.6 step 6).
3. Send FPWR datagrams in one frame:
   - `Registers.dc_sync0_cycle_time(cycle_ns)` → `0x09A0`
   - `Registers.dc_sync1_cycle_time(sync1_cycle_ns)` → `0x09A4`
   - `Registers.dc_pulse_length(pulse_ns)` → `0x0982`
   - `Registers.dc_sync0_start_time(start_time)` → `0x0990`
   - `Registers.dc_latch0_control(latch0_ctrl)` / `dc_latch1_control(latch1_ctrl)` → `0x09A8/0x09A9`
   - `Registers.dc_activation(0x03 | 0x07)` → `0x0981` (bits 0+1 always; bit2 when SYNC1 enabled)
4. In `:op`, if latches are configured, poll `0x09AE/0x09AF`; on captured edge read `0x09B0..0x09CF`, dispatch `{:slave_latch, ...}`, and call optional `on_latch/5`.
5. If the configuration transaction fails or any datagram returns an unexpected `WKC`, latch polling remains disabled and the transition fails.

All writes happen in one frame so the activation datagram sees already-written parameters.

EtherCAT epoch offset: `946_684_800_000_000_000` ns (difference between Unix epoch 1970 and EtherCAT epoch 2000-01-01).

### What is missing

- **CoE sync mode objects**: `0x1C32` (output sync parameters) and `0x1C33` (input sync parameters). These CoE objects configure the slave application's synchronization mode (free-run, SM event, SYNC0). Required for drives and other servo devices. Currently no support for reading or writing these.
- **DC lock detection**: should poll `0x092C–0x092F` (system time difference) and wait for lock before entering Op.
- **SYNC0 status acknowledgement**: in acknowledge pulse mode (`pulse_ns=0`), slave application must read `0x098E` to release each SYNC0 pulse.

---

## Key Design Decisions

**Why configure DC signals only after SAFEOP is confirmed?**
ETG.1020 §6.3.2 requires DC SYNC configuration after the slave has confirmed SafeOp. At this point FMMUs are already written during the PREOP-local setup step and the PDI is armed. Configuring earlier risks a race where the first SYNC0 pulse fires before the slave PDI is ready.

**Which bus transaction mode is used where?**
Configuration and mailbox writes use `Bus.transaction/2` because delivery matters more than strict timing.
Runtime latch polling in `:op` uses `Bus.transaction/3` with a timeout budget slightly below poll/cycle period so stale polls are dropped instead of queued, preventing recurring latch polls from building backlog on the bus.

**Where do ad-hoc SDO uploads/downloads live?**
`Slave.download_sdo/4` and `Slave.upload_sdo/3` run through the same mailbox counter and CoE transfer core used by PREOP `mailbox_config/1`. That keeps all mailbox sequencing in the slave process rather than exposing counter management to callers.

**Why send `{:slave_ready, name, :preop}` only after checked PREOP-local setup?**
Master waits for all named slaves to report `:preop` before advancing any slave to SafeOp/Op. In this implementation, that readiness signal means more than “AL state = PREOP”: it means mailbox parameterization and process-data SM/FMMU registration have already completed locally. That keeps activation aligned with the EtherCAT configuration sequence rather than racing ahead on AL state alone.

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
- No public object-dictionary browsing helpers beyond direct SDO upload/download calls.
- No over-sampling support (multiple input samples per SYNC0 period).
