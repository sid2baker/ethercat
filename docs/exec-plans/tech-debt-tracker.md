# Tech Debt Tracker

Known gaps and deferred work. Add entries when identified; move to `completed/` when resolved.

---

## DC / Synchronization

| Gap | Location | Impact | Notes |
|-----|----------|--------|-------|
| No maintained hardware validation for CoE sync-mode slaves (`0x1C32` / `0x1C33`) | `slave/sync/coe.ex`, examples | Drive-style sync-mode helpers exist but are not yet proven on a maintained live slave | The generic callback path is covered in tests |
| No static drift pre-compensation | `dc.ex` | ETG spec recommends ~15,000 ARMW warm-up frames; we start ticking immediately | Low practical impact on discrete I/O |

## Master

| Gap | Location | Impact | Notes |
|-----|----------|--------|-------|
| Slave fault classification is still too coarse | `master.ex`, `domain/cycle.ex` | `:operational` vs `:recovering` can be hard to reason about for PDO-participating slave faults | Promoted into the active plan `master-domain-fault-classification.md` |
| Sequential slave activation | `master.ex:do_activate` | Large slave counts are slow to activate (synchronous `Slave.request/2` per slave) | Parallel activation with barrier would speed startup |
| Topology limited to linear chain | `dc.ex` | DC delay calc fails for 3+ port branching topologies | Would require full §9.1.2.2 formula |
| No public redundancy status surface | `master.ex`, `domain.ex`, `bus.ex` | Runtime code cannot report whether redundant traffic is currently carrying the cycle | Link-level redundancy exists, but status is not yet surfaced as a first-class API |
| No IRQ-based slave event detection | `master.ex` | ECAT event request IRQ field in datagrams is not monitored | IRQ ORed across all slaves anyway; only useful with per-slave FPRD approach |

## Slave

| Gap | Location | Impact | Notes |
|-----|----------|--------|-------|
| No SYNC0 status acknowledgement | `slave.ex` | Pulse-mode slaves (`pulse_ns=0`) require reading `0x098E` to release each pulse | Affects acknowledge-mode operation |
| No over-sampling support | `slave.ex` | Cannot capture multiple input samples per SYNC0 period | Requires multiple SM channels per PDO |
| No backward ESM transition on error | `slave.ex` | If SafeOp→Op fails, slave may be left in unknown state | Should auto-retreat to PreOp |

## Domain

| Gap | Location | Impact | Notes |
|-----|----------|--------|-------|
| No overload/backpressure policy on signal fan-out | `domain/cycle.ex`, `slave/signals.ex` | Slow subscribers or slave-side consumers can accumulate messages | `send/2` is fire-and-forget; add mailbox size guard, cast drop, or explicit overload policy |
| Sub-byte PDOs are byte-padded | `slave.ex`, `domain.ex` | 1-bit digital channels waste 7 bits per channel in process image | Bit-level domain packing not implemented |
| No higher-level batched domain write API | `domain.ex`, `ethercat.ex` | Applications that stage many outputs must coordinate raw writes themselves | Current line intentionally keeps raw ETS staging and `write_output/3` as the public write boundary |

## Testing

| Gap | Location | Impact | Notes |
|-----|----------|--------|-------|
| No hardware-in-the-loop CI | `test/` | Hardware bugs only caught manually | Requires physical EK1100 + NIC in CI environment |
| No maintained local hardware smoke runner | `test/integration/hardware/README.md`, `docs/` | Hardware validation still depends on manual command selection and operator workflow | Maintained hardware scripts exist, but there is no single supported runner that executes the smoke matrix |
| SDO send/receive untested | `sii.ex`, `slave.ex` | CoE mailbox path has no automated coverage | |
| No DC timing accuracy test | `dc.ex` | PLL convergence not verified under load | |
