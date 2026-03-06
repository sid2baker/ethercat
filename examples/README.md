# EtherCAT Examples

Runnable scripts and Livebooks for testing the library against real hardware.

All scripts assume the 4-slave test ring unless noted:

```
EK1100 coupler (pos 0)
  └── EL1809  16-ch 24V digital input   (slave :inputs,  station 0x1001)
  └── EL2809  16-ch 24V digital output  (slave :outputs, station 0x1002)
  └── EL3202  2-ch PT100 RTD            (slave :rtd,     station 0x1003)
```

Each EL2809 output channel is wired to the matching EL1809 input channel (loopback).

---

## Running a script

```bash
mix run examples/<script>.exs --interface <eth-iface> [flags]
```

Raw Ethernet socket access requires `CAP_NET_RAW` or root.

---

## Scripts

### Bus diagnostics

| Script | What it does |
|--------|-------------|
| `probe.exs` | Raw AF_PACKET socket probe — bypasses the full stack to verify the physical layer |
| `diag.exs` | Socket diagnostic: system info, passive sniff, BRD round-trip, multi-frame burst |
| `scan.exs` | Scan the bus, assign station addresses, read SII identity for every slave |
| `bench.exs` | Link-layer latency benchmark — sends N BRD frames and reports RTT statistics |
| `udp_test.exs` | UDP/IP transport test (EtherCAT spec §2.6) |
| `sdo_debug.exs` | Mailbox / SDO diagnostic for the EL3202 CoE slave |

### Hardware validation (loopback ring)

| Script | What it does |
|--------|-------------|
| `io_quick.exs` | Quick cyclic I/O sanity check — write all outputs, read back inputs |
| `loopback.exs` | Inspect raw SII PDO configs and LRW frame data for EL2809 |
| `hardware_test.exs` | Full-stack stress test — cyclic I/O with miss counting |
| `el3202.exs` | EL3202 resistance-mode RTD readings via named-PDO API |
| `wiring_map.exs` | Commission-time loopback map — probe each output channel and find the matching input |

### Timing and performance

| Script | Flags | What it measures |
|--------|-------|-----------------|
| `cycle_jitter.exs` | `--period-ms` `--samples` `--bucket-us` | Domain cycle jitter via hardware loopback self-clock; reports p50/p95/p99/p99.9 and a histogram |
| `multi_domain.exs` | `--run-s` `--cross-samples` `--no-rtd` | Multi-rate multi-domain cycling (`:outputs` 1ms / `:inputs` 10ms / `:rtd` 50ms); cross-domain loopback latency; sub-ms feasibility probe |

### Slave behaviour

| Script | Flags | What it measures |
|--------|-------|-----------------|
| `watchdog_recovery.exs` | `--period-ms` `--poll-ms` `--trip-timeout` `--op-timeout` `--no-rtd` | SM watchdog trip and recovery — measures trip latency, reads WDT_status and WDT_SM registers, verifies safe-state loopback |
| `rtd_stability.exs` | `--period-ms` `--duration-s` `--report-s` `--sigma` | Long-duration RTD stability analysis — Welford running statistics, toggle-bit continuity, outlier detection |
| `dc_sync.exs` | `--period-ms` `--lock-timeout` `--drift-samples` `--lock-threshold` `--no-rtd` | Distributed Clocks test — DC lock convergence, per-slave system time via FPRD, sync-diff monitoring, loopback jitter baseline |

---

## Livebooks

Interactive Livebooks live under [`livebooks/`](livebooks/). Open them with
[Livebook](https://livebook.dev) using a **Mix project runtime** pointed at
this repository root.

| Notebook | What it covers |
|----------|---------------|
| `hardware_validation_livebook.livemd` | Full interactive hardware validation: startup, manual I/O, latency benchmarks, full-width loopback, priority stress, DC lock |
| `el1809_el2809_benchmarks.livemd` | Focused EL1809/EL2809 benchmarks and PDO inspection |

---

## Known constraints

| Constraint | Detail |
|------------|--------|
| **Minimum cycle time** | `cycle_time_us >= 1_000` (whole-millisecond; enforced in `Domain.Config`) |
| **SM → domain** | One SyncManager maps to exactly one domain; a slave's channels cannot be split across domains |
| **Logical base** | Multiple domains require non-overlapping `logical_base` values in `Domain.Config` (EL2809=2 B, EL1809=2 B, EL3202=8 B) |
| **DC capability** | EL1809, EL2809, EL3202 do not implement DC registers; only the EK1100 coupler responds to DC clock reads on this ring |
