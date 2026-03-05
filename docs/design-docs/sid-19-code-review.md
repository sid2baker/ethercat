# SID-19 Code Review (Spec-Guided)

Date: 2026-03-05

## Scope

Reviewed implementation behavior against the local spec summaries in `docs/references/ethercat-spec/` (especially chapters 04, 06, 11-21), plus architecture/context docs:

- `ARCHITECTURE.md`
- `lib/ethercat/master.md`
- `lib/ethercat/slave.md`
- `lib/ethercat/domain.md`

## Overall Assessment

The implementation is a solid pre-release baseline with clear module boundaries and a coherent startup/cyclic flow. It already covers core Class-B style operation: scan, station assignment, SII-driven SM/FMMU setup, cyclic LRW, and DC drift ticking.

Primary improvements are now in correctness hardening for fault/restart paths and stricter conformance checks in cyclic operation.

## Findings (Ordered by Severity)

### 1) High: Domain processes are not terminated with session shutdown

- Evidence:
  - Domains are started in `start_domains/2` ([master.ex](/home/n0gg1n/code/ethercat-workspaces/SID-19/lib/ethercat/master.ex#L546)).
  - `stop_session/1` terminates DC, slaves, and bus, but not domains ([master.ex](/home/n0gg1n/code/ethercat-workspaces/SID-19/lib/ethercat/master.ex#L748)).
- Spec alignment risk:
  - Startup/recovery sequence in chapters 17/20 assumes a clean re-initialization path. Persisting stale domains violates this and risks stale ETS maps + stale bus pid references.
- Impact:
  - Restart can run against leftover domain state (old registrations, old link pid, non-`:open` state), causing registration failures or silent misrouting.
- Recommendation:
  - Make domains session-scoped and terminate them in `stop_session/1`.
  - Prefer starting domains under `SessionSupervisor` (same lifecycle as bus/DC) or track/terminate domain pids explicitly.

### 2) High: Slave init can fail permanently on transient AL transition errors

- Evidence:
  - `init/1` calls `do_transition(:init)` once and stops the process on error ([slave.ex](/home/n0gg1n/code/ethercat-workspaces/SID-19/lib/ethercat/slave.ex#L233)).
  - Retry logic exists only in `do_auto_advance/1` for INIT->PREOP ([slave.ex](/home/n0gg1n/code/ethercat-workspaces/SID-19/lib/ethercat/slave.ex#L459)).
- Spec alignment risk:
  - Chapter 06 requires transition timeout/error handling and retry/ack behavior. Hard stop on first transient fails this robustness expectation.
- Impact:
  - A temporary communication or AL error at startup can kill a slave process permanently (`:temporary` child), leading to master configure timeout.
- Recommendation:
  - Treat initial `:init` transition failures as retriable (same timeout retry pattern used in auto-advance), not fatal process stop.

### 3) High: Domain accepts any `wkc > 0` for LRW success instead of expected WKC

- Evidence:
  - Cycle success condition is `wkc > 0` ([domain.ex](/home/n0gg1n/code/ethercat-workspaces/SID-19/lib/ethercat/domain.ex#L306)).
- Spec alignment risk:
  - Chapters 04 and 20 require comparing actual WKC to expected WKC to detect partial participation/faults.
- Impact:
  - Partial data-path faults can be silently treated as valid cycles, allowing stale/invalid process data into control logic.
- Recommendation:
  - Track expected WKC per domain image and require exact match.
  - On mismatch, mark cycle missed, keep prior-safe outputs, and emit mismatch-specific telemetry.

### 4) High: Sub-byte packing helpers do not handle cross-byte bit fields

- Evidence:
  - `extract_sm_bits/3` and `set_sm_bits/4` sub-byte path assumes the field fits in one byte ([slave.ex](/home/n0gg1n/code/ethercat-workspaces/SID-19/lib/ethercat/slave.ex#L986), [slave.ex](/home/n0gg1n/code/ethercat-workspaces/SID-19/lib/ethercat/slave.ex#L1006)).
  - Logic uses a single-byte read and `skip_high = 8 - bit_in_byte - bit_size`; this breaks for fields spanning byte boundaries.
- Spec alignment risk:
  - Chapter 13 explicitly allows arbitrary bit alignment.
- Impact:
  - Misaligned fields wider than one byte can decode/encode incorrectly or crash.
- Recommendation:
  - Replace single-byte sub-byte path with generic bitstring slicing/insertion across arbitrary offsets and widths.
  - Add property tests for random `(bit_offset, bit_size)` combinations.

### 5) Medium: SyncManager reconfiguration does not explicitly deactivate before reprogramming

- Evidence:
  - Mailbox SM setup writes active configs directly ([slave.ex](/home/n0gg1n/code/ethercat-workspaces/SID-19/lib/ethercat/slave.ex#L968)).
  - Process SM config in `register_sm_group/5` also writes active config directly ([slave.ex](/home/n0gg1n/code/ethercat-workspaces/SID-19/lib/ethercat/slave.ex#L603)).
- Spec alignment risk:
  - Chapter 11 warns SM must be deactivated before reconfiguration.
- Impact:
  - Works on tolerant ESCs but can fail on stricter devices/reconfig paths.
- Recommendation:
  - Write activate byte `0x00`, program register block, then write activate `0x01`.

### 6) Medium: Master enters `:running` even when some slave state transitions fail

- Evidence:
  - `do_activate/1` logs transition failures but continues and returns data ([master.ex](/home/n0gg1n/code/ethercat-workspaces/SID-19/lib/ethercat/master.ex#L723)).
- Spec alignment risk:
  - Chapter 19 sequence expects successful SafeOp/Op transition validation for addressed slaves.
- Impact:
  - System may report running while some configured slaves are not in Op.
- Recommendation:
  - Fail activation (or enter explicit degraded state) if any required slave fails SafeOp/Op.

## Suggested Priority Order

1. Fix lifecycle/restart correctness (Findings 1 and 2).
2. Enforce strict LRW WKC validation (Finding 3).
3. Generalize bitfield pack/unpack correctness (Finding 4).
4. Tighten SM reconfiguration + activation admission criteria (Findings 5 and 6).

## Notes

Known gaps already listed in `docs/exec-plans/tech-debt-tracker.md` (DC lock detection, CoE sync mode objects, mailbox/test coverage) remain valid and consistent with this review.
