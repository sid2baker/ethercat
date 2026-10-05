# Hardware integration guide

Use a dedicated, non-production bench. These tests and scripts can assign station
addresses, change AL states, write SDO configuration, toggle outputs, and interrupt
cyclic operation. Isolate actuators and establish a hardware-safe state before
running them; software cleanup is not a safety mechanism.

For ordinary development, start with the
[simulator suite](../simulator/README.md). Hardware complements deterministic tests
with real NIC timing, device behavior, captures, and simulator-drift checks.

## Prerequisites

- Linux with raw Ethernet socket support and a dedicated EtherCAT interface.
- A powered ring matching the selected test or script's configuration.
- `CAP_NET_RAW` on the BEAM executable, or equivalent privileges. See the
  [root setup guide](../../../README.md#2-discover-your-hardware); granting a
  capability affects every application using that executable.
- No competing master, simulator, capture session, or bench script on the same
  interface. Stop the other process first; interface exclusivity spans BEAM nodes.
- A repository checkout with dependencies fetched. Scripts normally need
  `MIX_ENV=test` to compile the shared fixtures in `test/integration/support/`.

Read the chosen script's header and options before running it. Not every script
supports `--no-rtd` or the same flags. Never guess a device's position or substitute
a driver just because the terminal names look similar.

## Maintained bench

```text
position 0  EK1100 coupler             :coupler  station 0x1000
position 1  EL1809 16-channel input    :inputs   station 0x1001
position 2  EL2809 16-channel output   :outputs  station 0x1002
position 3  EL3202 2-channel PT100 RTD  :rtd      station 0x1003
```

Loopback scenarios wire each EL2809 output to the corresponding EL1809 input.
The basic `ring_test.exs` configures the first three devices; RTD-specific scripts
use the fourth. Check the actual ordered configuration in each script, including
any terminals retained only to preserve positions. Redundant tests require the
appropriate return connection to the second NIC, not merely a second interface.

## Discover before activating

Start with the scanner on a powered, isolated segment:

```bash
MIX_ENV=test mix run test/integration/hardware/scripts/scan.exs --interface eth0
```

Replace `eth0` with the dedicated bench interface. Scanning writes station
addresses; it is not passive monitoring and must not run beside an active master.
Confirm device identities and positions before proceeding to cyclic/output tests.
For application code, use the public `EtherCAT.Scan.scan/1` API.

## ExUnit hardware coverage

Hardware tests are excluded from normal `mix test`. Opt in to a specific file:

```bash
ETHERCAT_INTERFACE=eth0 mix test --include hardware test/integration/hardware/ring_test.exs
```

Transport configuration:

| Environment variable | Meaning |
|----------------------|---------|
| `ETHERCAT_INTERFACE` | Raw single-link master interface |
| `ETHERCAT_BACKUP_INTERFACE` | Second raw interface for redundant tests |
| `ETHERCAT_UDP_HOST` | Optional UDP integration endpoint, not a normal physical ESC |
| `ETHERCAT_UDP_BIND_IP` | Optional local UDP bind IP |
| `ETHERCAT_UDP_PORT` | UDP destination port; default `34980` |

If raw and UDP are both configured, the single-link suite runs the same assertions
once per configured transport. UDP requires a separately provided compatible
endpoint; setting an IP does not make a physical EtherCAT ring speak UDP.

For a prepared redundant bench:

```bash
ETHERCAT_INTERFACE=eth0 ETHERCAT_BACKUP_INTERFACE=eth1 \
  mix test --include hardware test/integration/hardware/redundant_ring_test.exs
```

## Choose a bench script

Most scripts use this invocation shape:

```bash
MIX_ENV=test mix run test/integration/hardware/scripts/<script>.exs --interface eth0 [flags]
```

Scripts take command-line options; ExUnit uses the environment variables above.
`diag.exs` is an IEx helper with its own invocation, not a normal CLI script.

| Goal | Script | Important effect or requirement |
|------|--------|---------------------------------|
| Identity and station discovery | [scan.exs](scripts/scan.exs) | Assigns stations; no concurrent master |
| Socket/interface diagnostics | [diag.exs](scripts/diag.exs) | Sniffs and transmits probes; follow its IEx instructions |
| Digital roundtrip | [loopback.exs](scripts/loopback.exs) | Writes outputs; requires matching loopback wiring |
| Channel-to-channel wiring check | [wiring_map.exs](scripts/wiring_map.exs) | Activates output channels individually |
| Throughput and cycle timing | [bench.exs](scripts/bench.exs), [cycle_jitter.exs](scripts/cycle_jitter.exs) | Bench measurements, not real-time guarantees |
| DC and synchronization | [dc_sync.exs](scripts/dc_sync.exs) | Check device DC/SYNC capabilities first |
| Split-domain behavior | [multi_domain.exs](scripts/multi_domain.exs) | Digital loopback and optional RTD domain |
| RTD readings and stability | [el3202.exs](scripts/el3202.exs), [rtd_stability.exs](scripts/rtd_stability.exs) | EL3202 mailbox setup and typed input decode |
| Mailbox/register investigation | [sdo_debug.exs](scripts/sdo_debug.exs), [probe.exs](scripts/probe.exs) | Device-specific low-level operations |
| Failure and watchdog recovery | [fault_tolerance.exs](scripts/fault_tolerance.exs), [watchdog_recovery.exs](scripts/watchdog_recovery.exs) | Deliberately disruptive; isolated bench only |
| Redundant replug observation | [redundant_replug_watch.exs](scripts/redundant_replug_watch.exs) | Dual raw interfaces and controlled cable changes |
| UDP endpoint validation | [udp_transport.exs](scripts/udp_transport.exs) | Compatible UDP endpoint; read its distinct transport options |

## Promote a simulator regression

1. Capture or describe one real failure story.
2. Reproduce it in the smallest deterministic
   [simulator scenario](../simulator/SCENARIO_TEMPLATE.md).
3. Assert the degraded interval, retained fault, and recovery target—not only
   eventual return to `:operational`.
4. Fix the smallest responsible layer and rerun the targeted and broader tests.
5. Select a safe bench check that answers a physical question the simulator cannot.

Record the commit, device identities/revisions, wiring, interface/NIC, backend,
cycle/DC settings, fault procedure, and observed status/telemetry. Keep failures
visible. A passing simulator case does not prove hardware timing, and a passing
hardware smoke run does not replace deterministic recovery coverage.
