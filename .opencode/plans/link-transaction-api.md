# EtherCAT Link Transaction API Refactor

## Goal

Refactor `EtherCAT.Link` public API from 15+ per-command convenience functions to 3 public items: `start_link/1`, `transaction/2`, and `Transaction` builder module, with a `Result` struct replacing raw `%Datagram{}` in responses.

## Key Decisions

1. `Result` struct has: `data`, `wkc`, `circular`, `irq` (binary <<_::16>>). No `command` field -- callers rely on positional correspondence.
2. WKC returned raw -- data link layer returns facts, callers interpret.
3. `irq` stored as 2-byte little-endian binary for pattern matching.
4. Per-datagram unique IDX in Normal (spec Table 3: IDX is per-datagram identifier).
5. Redundant module left untouched for now.
6. Transaction is a dumb accumulator -- no validation at build time.
7. No meta field on Datagram -- unnecessary without Result.command.

## Files to Create

### 1. `lib/ethercat/link/result.ex`

New file. `%Result{data, wkc, circular, irq}` struct.

### 2. `lib/ethercat/link/transaction.ex`

New file. Opaque struct with `datagrams: []`. 14 builder functions (fprd/4, fpwr/4, fprw/4, frmw/4, aprd/4, apwr/4, aprw/4, armw/4, brd/3, bwr/3, brw/3, lrd/3, lwr/3, lrw/3) plus `new/0`. Each appends via `Command` module.

### 3. `test/ethercat/link/transaction_test.exs`

Pure unit tests for Transaction builder -- no hardware/socket needed.

## Files to Edit

### 4. `lib/ethercat/link/normal.ex`

- Rename `expected_idx` to `expected_idxs` in defstruct
- Per-datagram sequential IDX stamping via `Enum.map_reduce`
- Response matching via idx_map lookup + reorder to expected order
- Update `reply_and_idle` to clear `expected_idxs`

### 5. `lib/ethercat/link.ex`

- Delete all 15 per-command public functions (fprd, fpwr, fprw, frmw, aprd, apwr, aprw, armw, brd, bwr, brw, lrd, lwr, lrw) and public `transact/2`
- Add `transaction/2` with `(server, (Transaction.t() -> Transaction.t()))` signature
- Map response datagrams to `[%Result{}]` with irq converted to binary
- Update moduledoc with new examples
- Update aliases: add Transaction, Result; remove Command

### 6. `lib/ethercat/sii.ex`

- Add `alias EtherCAT.Link.Transaction`
- Rewrite `read_reg/4` wrapper: `Link.transaction` + `Transaction.fprd` + wkc check
- Rewrite `write_reg/4` wrapper: `Link.transaction` + `Transaction.fpwr` + wkc check

### 7. `lib/ethercat/slave.ex`

- Add `alias EtherCAT.Link.Transaction`
- `do_transition/2` (line 204): fpwr -> transaction
- `poll_al/3` (line 212): fprd -> transaction
- `ack_error/1` (lines 234, 240, 245): 3 fprd/fpwr calls -> transaction

### 8. `lib/ethercat/master.ex`

- Add `alias EtherCAT.Link.Transaction`
- `stable_count/1` (line 235): brd -> transaction, extract wkc as slave count
- `assign_stations/3` (line 250): apwr -> transaction

### 9. `lib/ethercat/io.ex`

- Add `alias EtherCAT.Link.Transaction`
- `cycle/3` (line 103): lrw -> transaction
- `write_reg/4` (line 245): fpwr -> transaction

### 10. `lib/ethercat/live.ex`

- Add `alias EtherCAT.Link.Transaction`
- All 8 Link call sites migrated to transaction/2 pattern
- Return types change to expose Result struct to IEx user

### 11. `test/ethercat_test.exs`

- Replace dead test (references nonexistent EtherCAT.Driver) with basic placeholder

## Files NOT Changed

- `lib/ethercat/link/redundant.ex` — explicitly excluded
- `lib/ethercat/link/datagram.ex` — no meta field needed
- `lib/ethercat/link/command.ex` — unchanged, still internal
- `lib/ethercat/link/frame.ex` — internal codec, unchanged
- `lib/ethercat/link/socket.ex` — unrelated
- `lib/ethercat/telemetry.ex` — API unchanged
- `lib/ethercat/application.ex` — unrelated
- `lib/ethercat.ex` — delegates to Master, unaffected
- `examples/diag.exs` — uses internal modules directly
- `examples/io_quick.exs` — goes through Master

## Execution Order

1. Create `result.ex`
2. Create `transaction.ex`
3. Edit `normal.ex` (per-datagram IDX)
4. Rewrite `link.ex` (transaction/2, delete old API)
5. Migrate callers: sii.ex, slave.ex, master.ex, io.ex, live.ex
6. Rewrite tests
7. `mix compile --warnings-as-errors`
