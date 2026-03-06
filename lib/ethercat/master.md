# EtherCAT.Master — Agent Context Briefing

## Purpose

`EtherCAT.Master` is the singleton `gen_statem` registered as `EtherCAT.Master` (local name).
It coordinates the entire bus startup sequence: bus open, slave count stabilization, station
assignment, DC initialization, slave spawning, and transition to operational state.

Supervised as `:permanent` under `EtherCAT.Application`. Started at application boot, not
restarted on individual slave crashes.

---

## States

```
:idle → :scanning → :configuring → (:running | :degraded)
         ↑ (on failure or stop, returns to :idle)
```

| State | Description |
|-------|-------------|
| `:idle` | Not started. Rejects all calls except `start/1`. |
| `:scanning` | Bus open, polling for a stable slave count via BRD to `0x0000`. |
| `:configuring` | Stations assigned, DC initialized, slaves spawned. Waiting for all named slaves to send `{:slave_ready, name, :preop}`. |
| `:running` | Startup sequence complete. Either operational, or waiting in PREOP for explicit `configure_slave/2` + `activate/0`. |
| `:degraded` | Startup is partially complete; at least one slave failed PREOP→SAFEOP/OP. Master retries failed promotions periodically and moves to `:running` once all succeed. |

Public lifecycle code should prefer `phase/0` over raw `state/0`:

- `:idle`
- `:scanning`
- `:configuring`
- `:preop_ready`
- `:operational`
- `:degraded`

---

## Scanning Phase

Entry action: immediately schedule `{:timeout, :scan_poll}` with 0 ms delay.

On each scan poll:
1. `Bus.transaction(bus, Transaction.brd(Registers.esc_type()))` — BRD to the ESC type register (`0x0000`). WKC = number of responding slaves.
2. Append `{monotonic_ms, wkc}` to sliding window; trim entries older than `scan_stable_ms + scan_poll_ms` (1100 ms window).
3. Stable when: window spans ≥ 1000 ms, ≥ 2 readings, all readings identical, count > 0.
4. On stability: tune bus frame timeout (`Bus.set_frame_timeout/2`) from slave count and cycle budget, then call `configure_network/1` synchronously and transition to `:configuring` or `:running` (the latter if no named slaves).
5. On BRD failure: reset window, reschedule after `scan_poll_ms` (100 ms).

---

## Configuration Phase (`configure_network/1`)

Runs synchronously inside the scan poll handler before any state transition.

**Step 1: Assign station addresses**
APWR to each slave by auto-increment position (0 to count-1), writing `base_station + pos` to register `0x0010`. Default `base_station = 0x1000`.

**Step 2: Read DL status**
FPRD `0x0110–0x0111` from each slave — 2-byte DL status. Passed to `DC.initialize_clocks/2` to determine topology (which ports are open).

**Step 3: Reset and verify Init**
`BWR 0x0120 = 0x0011` broadcasts an Init request with Error Acknowledge set.
Then the master polls each slave's `0x0130` until every node reports clean
Init state before any PREOP startup work begins.

**Step 4: DC initialization**
`DC.initialize_clocks(bus, slave_stations)` — see DC section below. Returns `{:ok, ref_station}` or `{:error, reason}`.

If DC init fails, master proceeds without DC: `dc_cycle_ns` is set to `nil`, no SYNC0 will be configured on any slave.

**Step 5: Start domains**
`start_domains/1` starts one `EtherCAT.Domain` gen_statem per domain config entry via `EtherCAT.SessionSupervisor` (session-scoped lifecycle, torn down by `stop_session/1`). Domains must exist before slaves call `Domain.register_pdo/4` in their `:preop` enter handler. Each domain registers itself in `EtherCAT.Registry` under `{:domain, id}`.

**Step 6: Start slaves**
`start_slaves/3` — one `EtherCAT.Slave` gen_statem per config entry via `EtherCAT.SlaveSupervisor`. `nil` config entries are rejected at `start/1`. Missing drivers use `EtherCAT.Slave.Driver.Default`.

If `slaves: []` (or omitted), the master auto-creates one default slave config per discovered station (`:coupler`, `:slave_1`, ...), starts all of them with `process_data: :none` and `target_state: :preop`, and tracks them in `pending_preop` so each process still executes INIT→PREOP.

Slaves receive `dc_cycle_ns` only if DC init succeeded (otherwise `nil`).

Each slave auto-advances to `:preop` concurrently in its own init. When it reaches `:preop`, it sends `{:slave_ready, name, :preop}` to the `EtherCAT.Master` process.

If the configured slave count exceeds the discovered slave count, startup fails
before any slave process is started.

---

## Configuring Phase

Waits for all entries in `pending_preop` to be removed by `{:slave_ready, name, :preop}` messages.

30-second timeout (`@configuring_timeout_ms`). On timeout: log error, call `stop_session/1`, reply `{:error, :configuring_timeout}` to any blocked `await_running` callers, return to `:idle`.

When `pending_preop` empties: call `activate_network/1` and transition to
`:running` when all activatable slaves reach OP, otherwise `:degraded`.

---

## Activation (`activate_network/1`)

Runs synchronously before transitioning to `:running`.

If no activatable slaves are configured, activation is skipped and the master enters `:running` with all slaves held in `:preop`. At that point:

1. call `configure_slave/2` one or more times
2. call `activate/0` once to start DC/domain runtime and request `SAFEOP -> OP`

**Step 1: Start DC gen_statem**
`DC.start_link(bus: bus, ref_station: ref_station, period_ms: 10)` — starts cyclic ARMW ticker.
Started *after* all slaves reach `:preop` so DC ticks don't compete with slave SM transitions on the socket.

**Step 2: Start domain cycling**
`Domain.start_cycling(id)` for each domain. Domains begin the self-timed LRW cycle.

**Step 3: Advance slaves to SafeOp**
`Slave.request(name, :safeop)` sequentially for each named slave. Synchronous — blocks until slave confirms SafeOp (or fails).

**Step 4: Advance slaves to Op**
`Slave.request(name, :op)` sequentially for each named slave.

If any activatable slave fails SafeOp/Op, master enters `:degraded` and retries failed slaves with `Slave.request(name, :op)` every second until all are in OP.

---

## Running Phase

Master accepts `stop/0`, `slaves/0`, `bus/0`, `state/0`, `await_running/1`, `configure_slave/2`, and `activate/0`.
Ignores `{:slave_ready, ...}` (stale from restart race).
On bus crash (`{:DOWN, ref, ...}`): calls `stop_session/1`, replies `{:error, {:bus_down, reason}}` to blocked callers, returns to `:idle`.

`await_running/1` means "startup finished". For static configurations that normally
also means operational. For dynamic PREOP configuration, use `await_operational/1`
after `activate/0`.

## Degraded Phase

Master accepts the same APIs as `:running`, but `await_running/1` returns
`{:error, {:activation_failed, failures}}` until recovery succeeds.
On each retry timeout, master attempts OP promotion for failed slaves and
transitions to `:running` once failures clear.

---

## DC Initialization (`EtherCAT.DC.initialize_clocks/2`)

Implements ESC datasheet §9.1.3.6 (clock synchronization initialization):

1. **Trigger receive-time latch**: BWR to `0x0900` — all slaves simultaneously latch local time at all ports.
2. **Read one DC snapshot per slave**: one reliable transaction per station reads:
   - `0x0918–0x091F` (64-bit ECAT receive time)
   - `0x0900–0x090F` (receive times for ports 0..3)
   - `0x0930–0x0931` (speed counter start)
3. **Derive active ports from DL status**: `EtherCAT.DC.Snapshot` combines the latched receive times with the `0x0110` DL status already read by the master, so the planner only considers ports that actually participate in the topology.
4. **Find reference clock**: first DC-capable snapshot in bus order.
5. **Build init plan**: `EtherCAT.DC.InitPlan.build/2` computes:
   - reference offset against the EtherCAT epoch time
   - per-slave offset relative to the reference receive time
   - chain-only cumulative propagation delay from receive spans
6. **Write offset + delay**: one reliable transaction per DC-capable slave writes:
   - `0x0920–0x0927` system time offset
   - `0x0928–0x092B` system time delay
7. **Reset PLL filters**: FPWR the latched `0x0930–0x0931` value back to each DC-capable slave.

`master_ns = System.os_time(:nanosecond) - 946_684_800_000_000_000` (converts Unix ns to EtherCAT epoch ns).

---

## DC Drift Maintenance (`EtherCAT.DC`)

`DC` is a `gen_statem` in state `:running`. On each tick (default 10 ms):
```
Bus.transaction(bus, Transaction.armw(ref_station, Registers.dc_system_time()))
```
ARMW to `0x0910` of reference clock: the reference clock's 64-bit system time is read into the datagram; all downstream slaves in the ring write the datagram value to their own `0x0910`. Each slave's PLL computes `Δt` and adjusts clock speed.

Uses `Bus.transaction/3` (direct, not queued) with a timeout budget derived from the DC tick period, to avoid ordering issues with other concurrent datagrams while dropping stale ticks.

Telemetry: `[:ethercat, :dc, :tick]` with `%{wkc: wkc}` on each tick.

---

## Struct Fields

```elixir
%EtherCAT.Master{
  bus_pid:         pid() | nil,
  bus_ref:         reference() | nil,    # Process.monitor ref for bus crash detection
  dc_pid:          pid() | nil,          # DC gen_statem pid
  dc_ref_station:  non_neg_integer() | nil,  # Station of reference clock slave
  slave_config:    list(),               # Raw slave config entries from start/1
  domain_config:   list(),               # Raw domain config entries from start/1
  dc_cycle_ns:     pos_integer() | nil,  # SYNC0 period; nil if no DC
  frame_timeout_override_ms: pos_integer() | nil, # Optional fixed bus frame timeout
  base_station:    non_neg_integer(),    # Default 0x1000
  slaves:          [{name, station, pid}], # Named slave tuples
  activatable_slaves: [atom()],          # Slaves to auto-advance PREOP→OP
  scan_window:     [{ms, count}],        # Sliding stability window
  slave_count:     non_neg_integer() | nil,
  pending_preop:   MapSet.t(),           # Names not yet reporting :preop
  activation_failures: %{atom() => {:safeop | :op, term()}},
  await_callers:   [from],              # Blocked await_running callers
}
```

---

## Known Gaps

- **No per-slave monitoring after Op**: master does not poll AL status or error counters on running slaves. Slave crashes are not detected by the master (only bus crashes trigger recovery).
- **Sequential slave activation**: slaves are advanced to SafeOp then Op one at a time via synchronous `Slave.request/2`. For large slave counts this can be slow. Parallel advancement (async + barrier) is not implemented.
- **No DC lock detection**: master does not wait for DC PLL to lock (read `0x092C` converging to 0) before advancing slaves to Op. Slaves enter Op before clocks are fully synchronized.
- **No static drift pre-compensation**: the datasheet recommends sending ~15,000 ARMW frames before operation to eliminate static drift. The DC gen_statem starts periodic ticking immediately without this warm-up phase.
- **No IRQ-based slave event detection**: master cannot receive slave-initiated events (AL state changes, error flags) without polling. The ECAT event request (`0x0210`) IRQ field in datagrams is not monitored.
- **Topology limited to linear chain**: DC delay calculation assumes a simple chain topology. Tree topologies with slaves having 3+ ports require the full formula from datasheet §9.1.2.2.
- **No master-level redundancy state API yet**: redundant links are handled inside the
  bus/link layer, but the master does not yet expose domain or link redundancy status
  as a first-class runtime API.
