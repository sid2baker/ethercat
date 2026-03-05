# Tech Debt Tracker

Known gaps and deferred work. Add entries when identified; move to `completed/` when resolved.

---

## DC / Synchronization

| Gap | Location | Impact | Notes |
|-----|----------|--------|-------|
| No CoE sync mode config (0x1C32/0x1C33) | `slave.ex` | Servo drives require this SDO write to enter DC SYNC mode | Must pair with SYNC0 changes |
| No DC lock detection | `master.ex`, `dc.ex` | Slaves enter Op before PLL converges; small timing error at startup | Poll `0x092C` until near zero before Op |
| No static drift pre-compensation | `dc.ex` | ETG spec recommends ~15,000 ARMW warm-up frames; we start ticking immediately | Low practical impact on discrete I/O |

## Master

| Gap | Location | Impact | Notes |
|-----|----------|--------|-------|
| No per-slave health monitoring after Op | `master.ex` | Slave ESM errors (e.g., watchdog timeout) are not detected without external polling | Would need periodic FPRD `0x0130` per slave |
| Sequential slave activation | `master.ex:do_activate` | Large slave counts are slow to activate (synchronous `Slave.request/2` per slave) | Parallel activation with barrier would speed startup |
| Topology limited to linear chain | `dc.ex` | DC delay calc fails for 3+ port branching topologies | Would require full §9.1.2.2 formula |
| No redundancy support | `master.ex`, `bus.ex` | Assumes single-segment bus | Requires second NIC + redundant frame injection |
| No IRQ-based slave event detection | `master.ex` | ECAT event request IRQ field in datagrams is not monitored | IRQ ORed across all slaves anyway; only useful with per-slave FPRD approach |

## Slave

| Gap | Location | Impact | Notes |
|-----|----------|--------|-------|
| SDO config failures masked | `slave.ex:run_sdo_config` | Logged as warning but state transition proceeds | Could mask silent misconfiguration on servo drives |
| No SYNC0 status acknowledgement | `slave.ex` | Pulse-mode slaves (`pulse_ns=0`) require reading `0x098E` to release each pulse | Affects acknowledge-mode operation |
| No over-sampling support | `slave.ex` | Cannot capture multiple input samples per SYNC0 period | Requires multiple SM channels per PDO |
| No backward ESM transition on error | `slave.ex` | If SafeOp→Op fails, slave may be left in unknown state | Should auto-retreat to PreOp |

## Domain

| Gap | Location | Impact | Notes |
|-----|----------|--------|-------|
| No per-PDO timestamp | `domain.ex` | Application cannot detect stale inputs | Could be added to ETS record as `{key, value, pid, last_changed_us}` |
| No backpressure on slave pid notification | `domain.ex:dispatch_inputs` | Slow slaves accumulate messages | `send/2` is fire-and-forget; add mailbox size guard or cast drop |
| No max frame size guard | `domain.ex` | `image_size` > ~1486 bytes silently fails at LRW level | Add assertion in `start_cycling/1` |
| Sub-byte PDOs are byte-padded | `slave.ex`, `domain.ex` | 1-bit digital channels waste 7 bits per channel in process image | Bit-level domain packing not implemented |

## Testing

| Gap | Location | Impact | Notes |
|-----|----------|--------|-------|
| No hardware-in-the-loop CI | `test/` | Hardware bugs only caught manually | Requires physical EK1100 + NIC in CI environment |
| SDO send/receive untested | `sii.ex`, `slave.ex` | CoE mailbox path has no automated coverage | |
| No DC timing accuracy test | `dc.ex` | PLL convergence not verified under load | |
