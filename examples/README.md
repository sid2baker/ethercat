# EtherCAT Examples

Runnable scripts and Livebooks for testing the library against real hardware.
If you are starting fresh, use the Livebooks first. They are the maintained,
interactive harnesses.

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

## Start Here

Open one of these Livebooks with [Livebook](https://livebook.dev) using a
**Mix project runtime** pointed at the repository root.

| Notebook | What it covers |
|----------|---------------|
| `livebooks/hardware_validation_livebook.livemd` | Full interactive hardware validation: startup, manual I/O, latency benchmarks, full-width loopback, priority stress, DC lock |
| `livebooks/el1809_el2809_benchmarks.livemd` | Focused EL1809/EL2809 benchmarks and PDO inspection |

If you prefer scripts, start with the maintained ones below. Some older
low-level scripts in `examples/` are historical maintainer probes and may lag
the current public API.

## Maintained Scripts

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
| `el3202.exs` | EL3202 resistance-mode RTD readings via named-PDO API |
| `wiring_map.exs` | Commission-time loopback map — probe each output channel and find the matching input |
| `loopback.exs` | Inspect raw SII PDO configs and current LRW-facing state for the EL2809 |

### Timing and performance

| Script | Flags | What it measures |
|--------|-------|-----------------|
| `cycle_jitter.exs` | `--period-ms` `--samples` `--bucket-us` | Domain cycle jitter via hardware loopback self-clock; reports p50/p95/p99/p99.9 and a histogram |
| `multi_domain.exs` | `--run-s` `--cross-samples` `--no-rtd` | Split-SM multi-rate cycling (`:fast` 1ms / `:slow` 10ms / `:rtd` 50ms); loopback latency on shared digital SyncManagers; sub-ms feasibility probe |

### Slave behaviour

| Script | Flags | What it measures |
|--------|-------|-----------------|
| `watchdog_recovery.exs` | `--period-ms` `--poll-ms` `--trip-timeout` `--op-timeout` `--no-rtd` | SM watchdog trip and recovery — measures trip latency, reads WDT_status and WDT_SM registers, verifies safe-state loopback |
| `rtd_stability.exs` | `--period-ms` `--duration-s` `--report-s` `--sigma` | Long-duration RTD stability analysis — Welford running statistics, toggle-bit continuity, outlier detection |
| `dc_sync.exs` | `--period-ms` `--lock-timeout` `--drift-samples` `--lock-threshold` `--no-rtd` | Distributed Clocks test — DC lock convergence, per-slave system time via FPRD, sync-diff monitoring, loopback jitter baseline |

## Removed legacy scripts

The following historical examples were removed because they targeted obsolete
APIs and were superseded by the maintained scripts and Livebooks above:

- `io_quick.exs` (removed; superseded by Livebooks and current examples)
- `hardware_test.exs` (removed; superseded by `livebooks/hardware_validation_livebook.livemd`)

---

## Known constraints

| Constraint | Detail |
|------------|--------|
| **Minimum cycle time** | `cycle_time_us >= 1_000` (whole-millisecond; enforced in `Domain.Config`) |
| **FMMU budget** | Each `{domain, SyncManager}` attachment consumes one FMMU in that slave. Splitting one SM across `:fast` and `:slow` is supported, but it reduces the remaining attachment budget on that slave |
| **Logical base** | Domains still require non-overlapping `logical_base` values in `Domain.Config` so FMMU logical windows do not alias |
| **DC capability** | EL1809, EL2809, EL3202 do not implement DC registers; only the EK1100 coupler responds to DC clock reads on this ring |
