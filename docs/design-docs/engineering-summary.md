# EtherCAT Stack — Engineering Summary

A record of what was built, what was learned, and how the hardware actually works.
Covers the full implementation from link layer to Domain cyclic I/O, with hardware
observations from real Beckhoff EK1100/EL1809/EL2809 testing.

---

## Table of Contents

1. [What EtherCAT Is](#1-what-ethercat-is)
2. [The EtherCAT Wire Protocol](#2-the-ethercat-wire-protocol)
3. [The ESC — EtherCAT Slave Controller](#3-the-esc--ethercat-slave-controller)
4. [SyncManager — The Data Handoff Mechanism](#4-syncmanager--the-data-handoff-mechanism)
5. [FMMU — Logical to Physical Address Translation](#5-fmmu--logical-to-physical-address-translation)
6. [The EtherCAT State Machine (ESM)](#6-the-ethercat-state-machine-esm)
7. [SII EEPROM — Slave Identity and Configuration](#7-sii-eeprom--slave-identity-and-configuration)
8. [How a Single LRW Cycle Works](#8-how-a-single-lrw-cycle-works)
9. [The Software Stack](#9-the-software-stack)
10. [Domain — Self-Timed Cyclic Exchange](#10-domain--self-timed-cyclic-exchange)
11. [Hardware Observations](#11-hardware-observations)
12. [Performance](#12-performance)
13. [Pitfalls and Gotchas](#13-pitfalls-and-gotchas)

---

## 1. What EtherCAT Is

EtherCAT (Ethernet for Control Automation Technology) is a real-time industrial Ethernet
protocol developed by Beckhoff. Unlike standard Ethernet where the master sends packets
*to* a device, EtherCAT sends a single Ethernet frame *through* all devices in a ring.
Each slave reads and writes data in-place as the frame passes through — by the time the
frame returns to the master, all slaves have updated it. One frame, all slaves, one trip.

This is the core insight: EtherCAT achieves low latency and determinism not by being
faster, but by eliminating round-trips. A 1ms cycle touching 100 slaves is achievable
because all 100 slaves are addressed in the same single frame.

**Physical topology:** Daisy-chain ring. Port 0 is always the input port. The frame
enters port 0 of the first slave, exits port 1 (or 3 for branch), enters port 0 of the
next slave, and so on. The last slave closes the loop back to the master.

---

## 2. The EtherCAT Wire Protocol

An EtherCAT frame is a standard Ethernet frame with EtherType `0x88A4`. Inside the
payload are one or more **datagrams**, each targeting a specific slave or a logical
address range.

### Datagram structure

```
Cmd (1 byte)   — command type: FPRD, FPWR, LRW, BRD, etc.
Idx (1 byte)   — sequence number for matching request/response
Address (4)    — meaning depends on command type
Length (2)     — payload size + flags
IRQ (2)        — interrupt request bits
Data (n)       — the actual bytes being read or written
WKC (2)        — working counter
```

### Command types

| Cmd | Name | Addressing | Semantics |
|-----|------|------------|-----------|
| FPRD | Fixed Physical Read | station address + register offset | Read registers from one slave |
| FPWR | Fixed Physical Write | station address + register offset | Write registers to one slave |
| BRD | Broadcast Read | register offset | Read from all slaves simultaneously (ORed) |
| BWR | Broadcast Write | register offset | Write to all slaves simultaneously |
| APRD | Auto-increment Read | position index | Read during slave discovery (before addresses assigned) |
| APWR | Auto-increment Write | position index | Write during slave discovery |
| LRD | Logical Read | 32-bit logical address | Read from slaves via FMMU mapping |
| LWR | Logical Write | 32-bit logical address | Write to slaves via FMMU mapping |
| LRW | Logical Read-Write | 32-bit logical address | Read + Write via FMMU in one pass |

**LRW is the key command for cyclic I/O.** One LRW datagram at logical address `0x0000`
covering the full process image reads all inputs and writes all outputs in a single pass
through the ring.

### Working Counter (WKC)

Each slave increments the WKC when it successfully processes a datagram:
- Successful read: +1
- Successful write: +1
- Successful read+write (LRW): +3 if both, +2 if write only, +1 if read only

The master checks WKC after receiving the frame back. If WKC < expected, some slave
didn't respond — data may be stale.

---

## 3. The ESC — EtherCAT Slave Controller

The ESC is the silicon heart of every EtherCAT slave. Beckhoff makes several:
ET1100, ET1200, ET1400, ESC20, etc. The EL terminal modules use ET1100/ET1200 embedded.

The ESC has:
- **2–4 ports** (physical Ethernet or EBUS) for ring topology
- **Process data RAM** (typically 8–64KB starting at register `0x1000`)
- **Register space** (`0x0000–0x0FFF`) for control, status, SM, FMMU config
- **FMMU channels** (2–8) for logical address mapping
- **SyncManager channels** (4–8) for buffer-controlled data exchange
- **SII EEPROM interface** for slave identity and configuration

### Key register map

```
0x0000  ESC type / revision
0x0010  Configured station address
0x0100  DL control (loop/port control)
0x0110  DL status (link/port status)
0x0120  AL control   — master writes target state here
0x0130  AL status    — slave reports current state here
0x0134  AL status code — error code on failed transition
0x0200  ECAT event mask
0x0204  AL event mask / request
0x0300  RX error counters (per port)
0x0400  Watchdog divider
0x0500  SII EEPROM interface
0x0600  FMMU registers (16 bytes × up to 8 channels)
0x0800  SyncManager registers (8 bytes × up to 8 channels)
0x1000  Process data RAM starts here
```

---

## 4. SyncManager — The Data Handoff Mechanism

A SyncManager (SM) is a hardware gate in front of a region of the ESC's process data
RAM. Without SMs, the master and the slave's local PDI (microcontroller/ASIC) could
race to read/write the same memory simultaneously with no safe handoff.

SMs solve this with hardware-enforced buffer management and interrupt generation.

### Two SM modes

**Buffered mode (3-buffer):** Used for cyclic process data. Three equal-sized physical
buffers sit behind the SM. The producer always writes to the "next free" buffer; the
consumer always reads the "last consistently written" buffer. Old data is silently
dropped if written faster than read. This is perfect for I/O: you always want the
most recent value, not a queue of old values.

**Mailbox mode (1-buffer):** Used for acyclic protocols (CoE, FoE, SoE). Strict
handshake — the buffer is locked for writing until the consumer reads it, then locked
for reading until the producer writes again. No data is ever lost.

### SM register layout (8 bytes per channel, base `0x0800 + index × 8`)

```
+0:1  Physical start address  (u16 — where in process data RAM)
+2:3  Length                  (u16 — bytes)
+4    Control                 mode[1:0] | direction[3:2] | irqs[6:4] | sequential[7]
+5    Status                  (read-only) buffer status, interrupt flags
+6    Activate                bit[0] = enable
+7    PDI control             bit[0] = deactivate from PDI side
```

### SM control byte common values

| ctrl | Meaning |
|------|---------|
| `0x00` | Buffered, ECAT reads (input data) — no interrupts |
| `0x20` | Buffered, ECAT reads (input data) — AL event IRQ enabled |
| `0x24` | Buffered, ECAT writes (output data) — AL event IRQ |
| `0x44` | Buffered, ECAT writes (output data) — AL event IRQ + watchdog trigger |
| `0x26` | Mailbox, ECAT writes (master→slave mailbox receive) |
| `0x22` | Mailbox, ECAT reads (slave→master mailbox send) |

### 3-buffer memory layout

For a 2-byte SM starting at `0x1000`:
```
0x1000–0x1001  Buffer 0  (visible address — ECAT and PDI use this)
0x1002–0x1003  Buffer 1  (shadow — managed by ESC internally)
0x1004–0x1005  Buffer 2  (shadow — managed by ESC internally)
```
The ESC transparently redirects accesses to `0x1000` to whichever physical buffer is
"active" at that moment. The master never needs to know which physical buffer is current.

**Critical:** For 32-bit-wide ESCs (ET1100, ET1200), each buffer is padded to 4-byte
alignment. The same 2-byte SM would consume `0x1000–0x1003` per buffer, requiring
12 bytes total instead of 6.

### SM power-on state

An important finding from hardware debugging: **the SM is NOT pre-loaded from EEPROM
at power-on** in the preop state. The SM registers start zeroed (phys=0, len=0,
activate=0). The master must write the SM configuration before process data exchange
can begin. The EEPROM SII contains the *default* SM addresses as a reference, but
the master always writes them explicitly.

Once the master activates an SM (writes activate=1), the slave's PDI immediately
starts filling the SM buffers from its hardware (physical input pins, internal state,
etc.). The SM status register shows which buffer was last written.

---

## 5. FMMU — Logical to Physical Address Translation

The FMMU (Fieldbus Memory Management Unit) is the mechanism that makes LRW work. It
translates a position in the master's **logical address space** (a flat 32-bit range
shared across all slaves) to a **physical address** in the ESC's process data RAM.

Without FMMUs, the master would need a separate FPRD/FPWR datagram for every slave.
With FMMUs, one LRW datagram covers all slaves simultaneously — each slave's FMMU
extracts/injects its slice from the passing frame.

### FMMU register layout (16 bytes per channel, base `0x0600 + index × 16`)

```
+0:3    Logical start address   (u32, in master's flat address space)
+4:5    Length                  (u16, bytes)
+6      Logical start bit       (0–7, use 0 for byte-aligned)
+7      Logical stop bit        (0–7, use 7 for byte-aligned)
+8:9    Physical start address  (u16, must match the paired SM's start address)
+10     Physical start bit      (0, byte-aligned)
+11     Type                    0x01=read (master reads), 0x02=write (master writes)
+12     Activate                0x01=enabled
+13:15  Reserved (write 0)
```

### FMMU restrictions

- Two FMMUs of the same direction on one ESC must not overlap in logical space.
- If bit-wise mapping is used (start_bit ≠ 0 or stop_bit ≠ 7), leave ≥3 bytes gap
  between same-direction FMMUs on the same ESC.
- For byte-aligned mapping (start_bit=0, stop_bit=7), ranges can be adjacent.
- Bit-wise WRITE is only supported in the digital output register (`0x0F00:0x0F03`).
- FMMU indices must be globally unique across all PDO groups sharing an ESC. If two
  PDO groups on the same slave both declare FMMU index 0, the second write overwrites
  the first. This is a common configuration mistake.

### SM ↔ FMMU pairing rule

The FMMU's physical start address **must match** the SM's physical start address. The
FMMU type must match the SM direction:
- Input SM (ECAT reads): FMMU type = `0x01` (read)
- Output SM (ECAT writes): FMMU type = `0x02` (write)

---

## 6. The EtherCAT State Machine (ESM)

Every EtherCAT slave runs a state machine with 5 states. The master requests transitions
by writing to `AL control` (0x0120); the slave reports its actual state in `AL status`
(0x0130).

```
Init → PreOp → SafeOp → Op
  ↑       ↑       ↑
  └───────┴───────┴── backward transitions allowed

Bootstrap ↔ Init (for firmware update)
```

| State | Meaning |
|-------|---------|
| **Init** | ESC reset state. Register access only. No process data, no mailbox. |
| **PreOp** | Mailbox SMs configured and active. Master can read SII EEPROM, exchange CoE SDOs. |
| **SafeOp** | Process data SMs and FMMUs configured. Cyclic exchange starts, but outputs are held at safe values (zero/default). Inputs are live. |
| **Op** | Full operation. Both inputs and outputs are live. |
| **Bootstrap** | Firmware update mode. Only reachable from Init. |

### AL control / status register encoding

| Value | State |
|-------|-------|
| `0x01` | Init |
| `0x02` | PreOp |
| `0x03` | Bootstrap |
| `0x04` | SafeOp |
| `0x08` | Op |

Bit 4 of AL control is the error acknowledge bit. When a transition fails, the slave
sets the error bit in AL status and a code in AL status code (0x0134). The master
must read the error code and write AL control with the ack bit set alongside the
current state code to clear it.

### SM/FMMU configuration timing

SM and FMMU registers are written in the **PreOp → SafeOp** transition:
- The ESC accepts SM/FMMU register writes in any state (they are always writable).
- But process data exchange via FMMU only begins once the slave reaches SafeOp.
- Therefore: write SM config in PreOp, then request SafeOp; the slave transitions
  and immediately starts exchanging process data.

This is why PDO registration happens at `:safeop` entry in the Slave gen_statem —
it's the first moment that SM/FMMU configuration has taken effect AND the master
has confirmed the transition.

---

## 7. SII EEPROM — Slave Identity and Configuration

Each slave has an I²C EEPROM connected to the ESC. The SII (Slave Information
Interface) EEPROM contains:
- Vendor ID and product code (used for driver lookup)
- Revision number and serial number
- Default SM channel configuration (addresses, sizes, ctrl bytes)
- Mailbox configuration (receive/send offset and size)
- PDO descriptions and CoE object dictionary references
- String data (device name, port names, etc.)

The master reads SII via ESC registers `0x0500–0x050F` using a simple protocol:
write the word address to `0x0504`, write the read command to `0x0502`, poll busy
bit, read data from `0x0508`.

SII uses **word addressing** (16-bit words). The fixed header occupies words 0x00–0x27.
Variable-length categories (strings, SM descriptions, PDO descriptions) follow from
word 0x40.

### Important SII header fields (word addresses)

```
0x00:0x01  PDI control and ESC configuration
0x04       Hardware delay
0x07:0x08  Vendor ID (32-bit)
0x08:0x09  Product code (32-bit)
0x0A:0x0B  Revision number (32-bit)
0x0C:0x0D  Serial number (32-bit)
0x18       Mailbox receive offset
0x19       Mailbox receive size
0x1A       Mailbox send offset
0x1B       Mailbox send size
```

The SM and FMMU configurations recommended by the manufacturer are in SII categories
(type codes 0x29 for SM, 0x33 for PDO). However, the master always writes these
registers directly — the SII values are advisory defaults, not automatically loaded
(except for the ESC configuration area which loads at power-on).

---

## 8. How a Single LRW Cycle Works

This is the complete picture of one cyclic process image exchange:

```
Master process image (logical address space, 4 bytes):
  [0x0000, 0x0001]  ← EL2809 output bytes (master writes)
  [0x0002, 0x0003]  ← EL1809 input bytes  (master reads)

LRW frame: cmd=LRW, address=0x00000000, length=4, data=[out0, out1, 0x00, 0x00]
```

1. **Frame sent.** Master builds an Ethernet frame with the LRW datagram and sends it.

2. **EK1100 (coupler).** Frame enters the coupler. EK1100 has no FMMU configured,
   so it passes the frame through unchanged. WKC unchanged.

3. **EL2809 (output terminal).** Frame enters. FMMU1 matches logical `0x0000–0x0001`
   → physical SM0 at `0x0F00`. ESC **writes** bytes `[out0, out1]` into the SM0 buffer.
   WKC += 1 (successful write). Outputs physically drive the terminal's 24V channels
   at the end of the frame (after FCS validated). Frame passes through unchanged.

4. **EL1809 (input terminal).** Frame enters. FMMU0 matches logical `0x0002–0x0003`
   → physical SM0 at `0x1000`. ESC **reads** from SM0 (which the PDI/hardware keeps
   current) and **injects** the 2 input bytes into the frame at position `[0x0002–0x0003]`.
   WKC += 1 (successful read). Frame now has live input data.

5. **Frame returns to master.** Master receives it. Checks WKC (expect 2 = 1 write +
   1 read). Extracts bytes `[2–3]` as EL1809 inputs. Updates ETS table.

The physical output signals change only after the frame's FCS is validated — not
mid-frame. This guarantees atomic updates.

---

## 9. The Software Stack

```
Application
    │
    ├── EtherCAT.Domain          self-timed cyclic I/O, ETS-based data exchange
    │       │
    │       └── EtherCAT.Slave.ProcessImage   stateless SM/FMMU config + LRW assembly
    │
    ├── EtherCAT.Master          slave discovery, ESM coordination
    │       │
    │       └── EtherCAT.Slave   per-slave gen_statem, ESM transitions
    │               │
    │               └── EtherCAT.Slave.SII     EEPROM read/write/reload
    │
    ├── EtherCAT.Slave.Registers  compile-time ESC register map
    └── EtherCAT.Link             raw Ethernet frame transport
            │
            ├── EtherCAT.Link.SinglePort   one interface
            └── EtherCAT.Link.Redundant    two interfaces
```

### Layer responsibilities

**Link layer** (`EtherCAT.Link`): Pure transport. Sends one Ethernet frame, waits
for the response, returns datagrams with their WKC values. Uses raw sockets via
`:socket` at `AF_PACKET` level. The `transaction/2` API takes a closure that builds
the datagram list; this prevents partial frame sends. Concurrent callers are serialised
by the Link gen_statem's `:postpone` mechanism — no external mutex needed.

**Slave layer** (`EtherCAT.Slave`): One gen_statem per physical slave. Manages the
ESM state machine (Init → PreOp → SafeOp → Op and backward). Reads SII EEPROM at
startup to get identity and mailbox config. Looks up the driver module by
`{vendor_id, product_code}`. At SafeOp entry, calls the driver's
`process_data_profile/0` and registers each PDO group with its target domain.

**ProcessImage** (`EtherCAT.Slave.ProcessImage`): Stateless utility. Given a list
of `{station, pid}` pairs and a profile map, writes SM and FMMU registers. Builds
the logical process image layout. The `cycle/3` function sends one LRW and returns
raw binary slices per station.

**Domain** (`EtherCAT.Domain`): Self-timed cyclic gen_statem. Drives the LRW period
via `state_timeout`. Owns one ETS table per domain for zero-overhead output/input
exchange. Multiple domains can run independently at different rates on the same Link.

**Driver behaviour** (`EtherCAT.Slave.Driver`): Implemented by the user for each
slave type. Three mandatory callbacks:
- `process_data_profile/0` — SM/FMMU hardware config + domain assignment
- `encode_outputs/1` — domain terms → raw binary
- `decode_inputs/1` — raw binary → domain terms

---

## 10. Domain — Self-Timed Cyclic Exchange

### The timing problem with Process.sleep

`Process.sleep(N)` has a ~1ms floor on stock Linux (kernel timer tick). A "4ms" sleep
actually sleeps 4–6ms. This makes the old `Master.cycle` approach unreliable below
~5ms effective period.

### The state_timeout solution

A gen_statem `state_timeout` uses the Erlang timer wheel, which fires via POSIX signals
and has the same ~1ms resolution floor. But the critical difference is **drift-free
period calculation**:

```elixir
# On each :cycling entry, compute delay to next absolute boundary
delay_us = max(0, data.next_cycle_at - System.monotonic_time(:microsecond))
delay_ms = div(delay_us + 999, 1000)  # ceiling — never fire early
```

`next_cycle_at` advances by exactly `period_us` on each cycle, regardless of how
long the LRW actually took. If one cycle runs long, the next fires sooner to compensate.
This prevents drift accumulation over thousands of cycles.

### Domain states

```
:open     — collecting register_pdo calls from slaves entering SafeOp
:cycling  — self-timed, fires LRW every period
:stopped  — halted; no timer
```

**Registration is deferred:** SM registers are written when `register_pdo` is called
(at SafeOp entry). FMMU registers are written at `start_cyclic` time. This two-phase
approach is critical — the logical offsets assigned to each slave's FMMU depend on
*all* slaves that have registered, so FMMUs can't be written until the full layout is
known.

**Layout building (two-pass):**
1. Pass 1: assign all output slices (outputs come first in logical space)
2. Pass 2: assign all input slices (after all outputs)

This guarantees outputs always occupy `[0, total_out_size)` and inputs occupy
`[total_out_size, total_out_size + total_in_size)`, regardless of registration order.

### ETS as the I/O boundary

Each domain owns a public ETS table named after its `:id`. Rows:
```
{station, outputs :: binary(), inputs :: binary(), updated_at :: integer()}
```

Application code reads/writes directly to ETS — no gen_statem hop, no message passing:
```elixir
# Zero-overhead output write
Domain.put_outputs(:fast, 0x1002, <<0xFF, 0xFF>>)

# Zero-overhead input read
{:ok, raw, timestamp} = Domain.get_inputs(:fast, 0x1001)
```

The Domain gen_statem updates the `inputs` and `updated_at` fields after each LRW,
and reads `outputs` when building the process image. ETS `update_element/3` with a
list is atomic, so applications always see a complete consistent row.

### Subscriber notifications

Applications can subscribe to receive `{:ethercat_domain, domain_id, :cycle_done}`
after each successful cycle. This is push-based: the application doesn't need to poll.
The subscriber pattern enables reactive control loops:

```elixir
Domain.subscribe(:fast)
receive do
  {:ethercat_domain, :fast, :cycle_done} ->
    {:ok, raw, _} = Domain.get_inputs(:fast, 0x1001)
    decoded = MyDriver.decode_inputs(raw)
    outputs = MyDriver.encode_outputs(compute_next(decoded))
    Domain.put_outputs(:fast, 0x1002, outputs)
end
```

---

## 11. Hardware Observations

From testing with EK1100 (coupler) + EL1809 (16-ch input) + EL2809 (16-ch output):

### SM not pre-loaded at power-on

**Finding:** The EL1809's SM0 registers read as all-zero (`phys=0, len=0, activate=0`)
when the slave is in PreOp, even though the SII EEPROM contains SM configuration data
at word `0x18+`.

**Explanation:** The SII EEPROM is loaded into ESC *configuration registers* (0x0140+)
at power-on, but the SyncManager registers (0x0800+) are NOT automatically populated.
The master always writes them explicitly. The SII SM data is advisory — the master
reads it to know *what* to write, but the actual writes happen every boot.

**Implication:** The Domain must always write SM registers when activating a slave.
Never assume power-on state matches SII defaults.

### 3-buffer physical layout

**Finding:** For a 2-byte SM at `0x1000`, the actual buffer locations are:
- Buffer 0: `0x1000–0x1001` (what ECAT and PDI address)
- Buffer 1: `0x1002–0x1003`
- Buffer 2: `0x1004–0x1005`

Data was observed at `0x1100` (which looks like "buffer 1 at stride 256") but this
was **stale RAM contents** from a different area, not related to the SM. The real
buffer stride equals the configured SM length.

### Input data follows output power supply

**Finding:** EL1809 inputs showed `0x0000` even with EL2809 outputs set to `ALL_ON`.
Root cause: the EL2809 requires a separate 24V supply on its output power contacts.
Without this supply, all output channels are dead (0V open-drain). Once 24V was
connected, the loopback worked immediately: `0xB7FF` with `ALL_ON` (14/16 channels
physically wired; 2 left open).

**Implication:** "Software works, hardware doesn't respond" often means a missing
power supply, not a software bug. Always verify the power supply first.

### SM ctrl byte write protection

**Finding:** The SM control register (`+4`) can only be written while the SM is
disabled (`activate=0`). Writing the full 8-byte SM block when the SM is already
active causes the ctrl byte write to be silently ignored, but all other bytes
(start address, length, activate) are written normally.

**Implication:** When re-configuring an active SM, disable it first (write activate=0),
then reconfigure, then re-enable. The current implementation writes the full block in
one FPWR during registration (SM starts disabled since it was never enabled before).
This is correct for initial configuration.

### FMMU index collision

**Finding:** Multiple PDO groups on the same ESC must use different FMMU indices.
If EL1809 declares FMMU index 0 and EL2809 also declares FMMU index 0 (both slaves
on the same domain), the second write overwrites the first. The result: one FMMU works,
one is silently broken.

**Solution:** FMMU indices must be unique per ESC. In practice, for Beckhoff I/O
terminals, the convention is:
- EL2809: FMMU0 for write (outputs)
- EL1809: FMMU0 for read (inputs)  — OR FMMU1 if sharing ESC with an output terminal

Since EL1809 and EL2809 are separate physical modules, each has its own ESC and its
own FMMU0. No collision. Collision only occurs when a single module has multiple PDO
groups (e.g., a servo drive with both fast torque PDOs and slow diagnostic PDOs on
the same ESC).

---

## 12. Performance

Measured on stock Linux (non-RT kernel) with EK1100 + EL1809 + EL2809 at various
periods:

| Period | avg | min | max | jitter | overruns |
|--------|-----|-----|-----|--------|----------|
| 4 ms | 5.0 ms | 4.5 ms | 5.9 ms | ~600 µs | 0 |
| 1 ms | 1.0 ms (domain) | — | — | — | — |

The **Domain cycle_count** reaches 1000 at 1ms with zero misses, confirming the domain
fires correctly at 1ms. The subscriber-side receive loop can't keep up at 1ms (it does
ETS reads and IO.puts between receives), so the subscriber timing numbers don't reflect
the domain timing.

**Practical floor on stock Linux:**
- Domain self-timer: reliable at 1ms (Erlang timer wheel + BEAM scheduler)
- Subscriber loop: reliable at ~3–5ms (OS scheduler wakeup latency)
- With PREEMPT_RT kernel: sub-1ms subscriber loops become feasible

**Raw LRW round-trip:** ~500µs (3-slave ring on 100BaseT, measured by Link.transaction
duration). The gen_statem call overhead adds ~100–300µs.

---

## 13. Pitfalls and Gotchas

### gen_statem self-transition doesn't trigger state_enter

**Problem:** `{:next_state, :cycling, new_data}` from within the `:cycling` state is a
self-transition. `state_enter` callbacks only fire on actual state *changes*, not
self-transitions. Using this to re-arm a `state_timeout` silently does nothing.

**Fix:** Use `{:keep_state, new_data, [{:state_timeout, delay_ms, :tick}]}` to
explicitly set the next timeout without leaving the state.

### gen_statem.call timeout raises an exit, not returns an error

**Problem:** `:gen_statem.call(pid, msg, 50)` with a 50ms timeout raises an exit signal
`{:exit, {:timeout, _}}` when it fires. This exit propagates up through `handle_event`
and crashes the calling gen_statem.

**Fix:** Wrap in `try/catch`:
```elixir
try do
  :gen_statem.call(link, {:transact, datagrams}, 50)
catch
  :exit, {:timeout, _} -> {:error, :timeout}
  :exit, reason -> {:error, reason}
end
```

### LRW logical address must match FMMU logical address exactly

**Problem:** If the domain's `logical_base` is `0x00000000` but the FMMU is written
with logical start `0x00000002`, the LRW covering `[0x0000, 0x0003]` will match the
FMMU (since it spans the FMMU's range). But if the LRW only covers `[0x0000, 0x0001]`
(2 bytes), it won't reach the FMMU at offset 2 — no data exchange, WKC unchanged.

Always ensure `image_size` covers all configured FMMUs.

### SM physical address in FMMU must exactly match SM start address

**Problem:** If SM0 starts at `0x1000` but the FMMU physical start is `0x1001`, the
FMMU matches but accesses byte 1 of the SM buffer (not the start). The SM protection
mechanism denies access to the buffer (start address rule) and returns zeros.

**Rule:** FMMU physical start = SM start address, always.

### EtherCAT requires stable slave count before assigning addresses

**Problem:** Immediately after plugging in slaves, the BRD WKC (counting slaves) may
fluctuate as terminator resistors settle. Assigning station addresses during this window
can result in partial assignment.

**Fix:** Poll 3 consistent identical BRD WKC readings before trusting the count. This
is implemented in `Master.stable_count/1`.

### Registry.register fails if domain is restarted

**Problem:** When a Domain gen_statem crashes and restarts, it calls
`Registry.register(EtherCAT.Registry, {:domain, id}, id)`. If the old registration
wasn't cleaned up, this fails.

**Fix:** Use `Registry.register` which returns `{:ok, _}` or `{:error, {:already_registered, _}}`.
In practice, since the Domain process is dead when it restarts, the Registry
automatically removes the old entry. This is only an issue if the Domain is restarted
while still running (which shouldn't happen with `:temporary` restart strategy).

---

## Conclusion

EtherCAT's power comes from three ideas working together:
1. **Frame-through processing** — one frame serves all slaves, dramatically reducing latency
2. **SyncManagers** — hardware-enforced buffer exchange eliminates software race conditions
3. **FMMUs** — logical address translation enables the master to treat all slaves as one flat address space

The Elixir implementation maps these concepts cleanly: Link layer handles the wire,
Slave handles the state machine, Domain handles the cyclic timing and data routing.
The ETS-based I/O boundary keeps the hot path free of gen_statem overhead, enabling
reliable 1ms cycle times on stock Linux hardware.
