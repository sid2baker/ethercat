# EtherCAT Slave Controller — Technology Reference

Covers Beckhoff ESC implementations: ET1200, ET1100, ET1150, EtherCAT IP core (V4.0), ESC20.
All registers are little-endian unless noted. Transmission order is LSB first.

---

## 1. ESC Architecture

An ESC connects the EtherCAT fieldbus to a slave application. The address space is 64 KB:
- `0x0000–0x0FFF`: registers and user RAM
- `0x1000–0xFFFF`: process data RAM (up to 60 KB)

Key functional blocks:
- **EtherCAT Processing Unit (EPU)**: logically between port 0 and port 3; processes all datagrams on-the-fly (no frame buffering). Source MAC bit 1 is set for any frame passing the EPU to distinguish outgoing from incoming frames.
- **Auto-forwarder**: receives frames, checks them, generates receive timestamps, forwards to loopback.
- **Loopback function**: routes frames to next open port; closes the loop at ports without link.
- **FMMU**: bitwise logical-to-physical address mapping (up to 16 channels).
- **SyncManager**: consistent data exchange with interrupt generation (up to 16 channels).
- **Distributed Clocks**: 64-bit ns clock; SYNC signal generation; LATCH event timestamping.
- **SII EEPROM**: I2C NVRAM holding ESI (slave information), mailbox config, PDO layout.
- **Monitoring**: error counters, watchdogs.

Feature summary by device:

| Feature            | ET1200  | ET1100  | ET1150   | IP core   | ESC20  |
|--------------------|---------|---------|----------|-----------|--------|
| Ports              | 2–3     | 2–4     | 1–4      | 1–4       | 2 MII  |
| FMMUs              | 3       | 8       | 16       | 0–16      | 4      |
| SyncManagers       | 4       | 8       | 16       | 0–16      | 4      |
| RAM (KB)           | 1       | 8       | 15       | 0–60      | 4      |
| DC width           | 64-bit  | 64-bit  | 64-bit   | 32/64-bit | 32-bit |

---

## 2. EtherCAT Protocol

EtherType `0x88A4`. Runs directly over Ethernet or encapsulated in UDP/IP.
ESCs process frames in hardware — no CPU involved.

### 2.1 Frame Layout

```
Ethernet header (14 B) | EtherCAT header (2 B) | 1..N datagrams | FCS (4 B)
```

**EtherCAT header** (16 bits):
- `[10:0]` Length: byte count of all datagrams (excl. FCS). Ignored by ESC; ESC relies on datagram length fields.
- `[11]` Reserved: 0
- `[15:12]` Type: must be `0x1` for EtherCAT commands

Minimum frame 64 bytes; padding added if needed. VLAN tags supported but contents ignored.

### 2.2 Datagram Structure

```
Cmd(8) | Idx(8) | Address(32) | Len(11) | R(3) | C(1) | M(1) | IRQ(16) | Data(N) | WKC(16)
```

| Field | Description |
|-------|-------------|
| Cmd   | Command type (see §2.5) |
| Idx   | Master-assigned identifier; slaves must not modify |
| Address | 32-bit: position+offset (auto-inc), station+offset (node), or logical address |
| Len   | Byte count of Data field |
| C     | Circulating frame bit: 0=not circulating, 1=has circulated once |
| M     | More datagrams follow: 0=last, 1=more |
| IRQ   | OR of all slaves' ECAT event request registers |
| WKC   | Working counter: incremented by each successfully addressed slave |

### 2.3 Addressing Modes

**Auto-increment (position) addressing**: Address holds negative position. Each slave increments it; slave acts when it reads zero. Use only at startup for scanning. Avoid after topology is known — hot-connect can shift positions.

**Configured station address (node) addressing**: Master assigns addresses via APWR at init; stored in `0x0010`. Slave also has an alias address from SII EEPROM at `0x0012` (loaded once at power-on, not on reload). Master must explicitly enable alias.

**Broadcast**: All slaves are addressed; all increment position.

**Logical addressing**: 4 GB logical space (32-bit). Slaves use FMMU to map regions to physical addresses. Supports bitwise mapping.

### 2.4 Working Counter (WKC)

WKC is 16 bits appended to each datagram. Incremented per ESC that successfully processes the datagram.

| Command type | No match | Successful read | Successful write | Read + write |
|-------------|---------|----------------|-----------------|-------------|
| Read        | +0      | +1              | —               | —           |
| Write       | +0      | —               | +1              | —           |
| Read-write  | +0      | +1              | +2              | +3          |

WKC increment requires at least one byte of the multi-byte datagram to be accessed. A full multi-byte access does not produce a higher WKC than a single-byte access.

### 2.5 Command Types

| CMD | Abbr. | Name                         | Description |
|-----|-------|------------------------------|-------------|
| 0   | NOP   | No operation                 | Slave ignores |
| 1   | APRD  | Auto-increment read          | Read if position=0; always increments position |
| 2   | APWR  | Auto-increment write         | Write if position=0 |
| 3   | APRW  | Auto-increment read-write    | Read+write if position=0 |
| 4   | FPRD  | Configured address read      | Read if station address matches |
| 5   | FPWR  | Configured address write     | Write if station address matches |
| 6   | FPRW  | Configured address read-write| Read+write if address matches |
| 7   | BRD   | Broadcast read               | All slaves: OR data into datagram |
| 8   | BWR   | Broadcast write              | All slaves write |
| 9   | BRW   | Broadcast read-write         | All slaves: OR+write (rarely used) |
| 10  | LRD   | Logical memory read          | Read via FMMU match |
| 11  | LWR   | Logical memory write         | Write via FMMU match |
| 12  | LRW   | Logical memory read-write    | Read+write via FMMU (used for cyclic I/O) |
| 13  | ARMW  | Auto-increment read multiple write | Position=0: read; position≠0: write. Used for DC drift. |
| 14  | FRMW  | Configured read multiple write | Address match: read; no match: write |

ARMW/FRMW: treated as read or write for WKC purposes (always +1 per slave, regardless of read or write).

For LRD/LRW: only bits covered by FMMU bitmask are read from physical memory; bits not covered keep their datagram value (allows OR-merging from multiple slaves into one logical byte).

### 2.6 UDP/IP Encapsulation

ESC matches: EtherType `0x0800`, IP protocol `0x11` (UDP), UDP dest port `0x88A4`. UDP checksum is cleared by ESC (cannot update it on-the-fly). All other IP/UDP fields are ignored.

---

## 3. Frame Processing

### 3.1 Loop Control

Each port state: open or closed. Controlled via DL control register `0x0100[15:8]`.

| Setting       | Behavior |
|---------------|----------|
| Manual open   | Port always open, regardless of link state |
| Manual close  | Port always closed |
| Auto          | Open if link present, closed if no link |
| Auto-close    | Closes on link loss; does not auto-reopen on link recovery. Reopens when master writes DL control again via another port, or when a valid Ethernet frame is received at the closed port |

If all ports are closed (automatic or manual), port 0 is opened as recovery port regardless.

**Key registers:**
- `0x0100[15:8]`: DL control — loop settings per port
- `0x0110[15:4]`: DL status — loop and link status
- `0x0110[15,13,11,9]`: communication established per port
- `0x0518–0x051B`: PHY port status

### 3.2 Frame Processing Order

| Ports | Order |
|-------|-------|
| 1     | 0 → EPU → 0 |
| 2     | 0 → EPU → 1 → 0 |
| 3     | 0 → EPU → 1 → 2 → 0 (ports 0,1,2) or 0 → EPU → 3 → 1 → 0 (ports 0,1,3) |
| 4     | 0 → EPU → 3 → 1 → 2 → 0 |

The path through the EPU is the "processing" direction; paths bypassing the EPU are "forwarding" direction. Processing delay > forwarding delay; this difference (`tDiff`) is used in propagation delay calculations.

### 3.3 Shadow Buffers

Register writes (`0x0000–0x0F7F`) use shadow buffers. The shadow is committed to the real register only if the frame FCS is valid. Register changes take effect after the FCS is received. Process RAM has no shadow buffer — writes take effect immediately even on frame error (but EPU operations like SyncManager buffer changes are discarded on errors).

### 3.4 Circulating Frame Prevention

When a port 0 auto-closes (link lost) and a frame arrives with circulating bit = 0, the ESC sets it to 1. If a frame arrives at port 0 (auto-closed) with circulating bit = 1, the frame is destroyed. This prevents circulating frames from triggering watchdogs when a ring breaks.

**Warning**: Do not leave port 0 intentionally unconnected. All frames will be dropped by the circulating frame mechanism.

### 3.5 Non-EtherCAT Frames

ESC destroys non-EtherCAT frames by default. Set `0x0100[0]=1` to forward them.

---

## 4. FMMU

FMMUs map one contiguous logical address range to one contiguous physical address range, with bit-level precision. Each FMMU channel is 16 bytes at `0x0600 + index * 16`.

### FMMU Register Layout

| Offset | Size | Field |
|--------|------|-------|
| 0x0–0x3 | 4 B | Logical start address (32-bit) |
| 0x4–0x5 | 2 B | Length in bytes |
| 0x6     | 1 B | Logical start bit (0–7) |
| 0x7     | 1 B | Logical stop bit (0–7) |
| 0x8–0x9 | 2 B | Physical start address |
| 0xA     | 1 B | Physical start bit (0–7) |
| 0xB     | 1 B | Type: `0x01`=read, `0x02`=write, `0x03`=read-write |
| 0xC     | 1 B | Activate: `0x01`=enabled |
| 0xD–0xF | 3 B | Reserved, 0 |

### Restrictions

- Adjacent FMMUs of the same direction using bitwise mapping must be separated by at least 3 logical bytes not covered by any FMMU of the same type.
- If all FMMU mappings in a slave are byte-aligned (start_bit=0, stop_bit=7, phys_start_bit=0), adjacent mappings are allowed.
- Bitwise writing is only supported for the digital output register (`0x0F00–0x0F03`). Other areas are always written byte-wise; unmapped bits get undefined values.
- Read FMMU: bits not mapped keep their datagram value (does not affect physical data).
- If two FMMUs of the same direction cover the same logical byte, the lower-numbered FMMU wins.
- A read/write FMMU cannot be used with SyncManagers (independent read+write SMs cannot share a physical address range).

---

## 5. SyncManager

SyncManagers enforce consistent, secure data exchange between master and slave application. They control access to a RAM buffer and generate interrupts/events.

**Access rule**: a buffer access must start at the buffer's start address. Any subsequent bytes in the buffer can be accessed in any order. Access completes when the end address is reached. The end address cannot be accessed twice within one frame. Buffer state changes and interrupts are generated after the end address is reached.

Align SM buffer start addresses to 64-bit (8-byte) boundaries.

### SM Register Layout (base `0x0800 + index * 8`)

| Offset | Field | Description |
|--------|-------|-------------|
| 0x0–0x1 | Physical start address | RAM address where SM buffer begins |
| 0x2–0x3 | Length | Buffer size in bytes |
| 0x4     | Control | See bit layout below |
| 0x5     | Status | Read-only state |
| 0x6     | Activate | Bit 0=enable SM; Bit 1=repeat request (mailbox) |
| 0x7     | PDI control | Bit 0=PDI deactivate request; Bit 1=repeat ack; Bit 6=deactivation delay enable; Bit 7=deactivation delay active |

**SM Control register `0x4` bit layout:**
- `[1:0]` Mode: `0b00`=buffered (3-buffer), `0b10`=mailbox
- `[3:2]` Direction: `0b00`=ECAT reads/PDI writes (input SM), `0b01`=ECAT writes/PDI reads (output SM)
- `[4]` ECAT interrupt enable
- `[5]` AL event interrupt enable
- `[6]` Watchdog trigger enable
- `[7]` Sequential mode (for large buffers >1 frame)

**SM Status register `0x5`:**
- `[1:0]` Last buffer index written (0–2; 3=start/empty)
- `[2]` Sequential mode error
- `[3]` Mailbox full (mailbox mode)
- `[5:4]` Last buffer used by PDI

### 5.1 Buffered Mode (3-buffer)

Three physical buffers of equal size. Only the start address of buffer 0 is configured; buffers 1 and 2 are invisible and unavailable for other use. The ESC redirects accesses to buffer 0's address range to the correct internal buffer based on state.

Memory layout for buffer size `N`, 8-bit ESC: buffers at configured_start, configured_start+N, configured_start+2N.

For 32-bit internal width ESCs: each buffer's start is rounded down to 32-bit boundary and end rounded up. Each buffer can occupy up to 6 extra bytes. Total SM reservation ≈ 3 × (N + 6 bytes alignment).

The producer can always write; the consumer always gets the latest complete buffer. Old data is dropped if written faster than read.

### 5.2 Mailbox Mode

Single buffer. Producer writes first; buffer is then locked for writing until consumer reads it completely. Alternating access guaranteed — no data loss.

Memory layout: only one buffer of configured size. No extra buffers.

**Mailbox repeat mechanism**: if a master read frame is lost, master toggles Repeat Request bit in SM Activate register `0x06[1]`. Slave (PDI) detects this (interrupt `0x0220[4]` or polling) and rewrites the stored last buffer. Slave then toggles Repeat Acknowledge bit in PDI control register `0x07[1]`. Master verifies and re-reads.

### 5.3 Mailbox Communication Protocols

Mailbox header (6 bytes): Length(16) | Address(16) | Channel(6)/Priority(2) | Type(4)/Counter(3)/Reserved(1)

Supported protocols (Type field):
- `0x0`: Error
- `0x1`: AoE (ADS over EtherCAT)
- `0x2`: EoE (Ethernet over EtherCAT)
- `0x3`: CoE (CAN application layer / object dictionary)
- `0x4`: FoE (File access / firmware update)
- `0x5`: SoE (Servo profile)
- `0xF`: VoE (Vendor specific)

### 5.4 SM Deactivation

PDI can deactivate an SM by writing `0x07[0]=1`. Master detects this via WKC not incrementing on SM buffer access. On PDI deactivation: SM state is reset, interrupts cleared, buffer must be written first after re-activation.

Master deactivation of a buffered SM: if PDI is reading at the moment of master deactivation, bytes may mix between buffers. An optional **deactivation delay** mode (`0x07[6]=1`) allows PDI to complete reading the last buffer while the SM appears disabled to the master. Transitional state must be exited within 6 µs of master deactivation; PDI must then set `0x07[0]=1`.

### 5.5 SM with Length ≤ 1 Byte

Length=1: buffer mechanism disabled; read/write passes through without SM interference. Watchdog trigger and interrupt still work. Used for digital output PDIs (one SM per output byte, buffered mode, watchdog trigger enabled).

Length=0: SM completely disabled.

---

## 6. Distributed Clocks

### 6.1 Overview

System time: nanoseconds since 2000-01-01 00:00:00 UTC. 64-bit value (some older ESCs: 32-bit lower half only, compatible). One ESC is the **reference clock** (typically first DC-capable slave). All others are **DC slaves** synchronized to it.

**Clocks:**
- `tLocal time`: free-running local counter since ESC power-on
- `tOffset`: written by master to each slave; `tSystem time = tLocal time + tOffset`
- `tPropagation delay`: written by master per slave; accounts for wire and processing delays

### 6.2 Propagation Delay Measurement

1. Master sends BWR to `0x0900` (at least first byte). All slaves latch their local time at all ports simultaneously.
2. Master reads per-port receive times (`0x0900–0x090F`, 32-bit each) and ECAT processing unit receive time (`0x0918–0x091F`, 64-bit) from each slave.
3. For a simple linear chain, delay between adjacent slaves A and B (with B downstream of A): `tAB = ((tA1 - tA0) - (tB_span) + tDiff) / 2` where `tA0`, `tA1` are A's port 0 and port 1 receive times, `tB_span` is B's port span, and `tDiff` is the per-ESC processing-minus-forwarding delay (from ESI).
4. Cumulative delay for each slave = sum of hop delays from reference clock.
5. Write cumulative delay to each slave's system time delay register `0x0928–0x092B`.

**Note**: Some ESCs latch the *next* frame after the BWR. The ring must be empty before sending the BWR latch trigger on those ESCs.

### 6.3 Initialization Sequence (ETG.1000 §9.1.3.6)

1. Read DL status of all slaves to determine topology.
2. BWR to `0x0900` — all slaves latch receive times.
3. Wait for frame to return.
4. FPRD receive times from every slave.
5. Calculate propagation delays; FPWR to `0x0928` on each slave.
6. Calculate and write system time offset to reference clock: `tOffset_ref = master_time - tLocal_ref`.
7. Calculate and write system time offset to each DC slave: `tOffset_slave = tLocal_ref - tLocal_slave + tOffset_ref`.
8. Reset PLL filters: read `0x0930–0x0931` (speed counter start) from each DC slave, write back the same value.
9. Static drift compensation: send ~15,000 ARMW frames targeting reference clock's system time register `0x0910`.
10. Ongoing dynamic drift: periodic ARMW/FRMW to `0x0910` of reference clock.

### 6.4 Drift Compensation

ARMW to reference clock `0x0910`: reference clock's system time is read into the datagram; downstream slaves each write the datagram value back to their own `0x0910`. The PLL in each slave computes `Δt = (tLocal + tOffset - tDelay) - tReceived` and adjusts local clock speed. `Δt` must stay below `2^30 ns` (~1 second) for stability.

**PLL registers:**

| Register | Description |
|----------|-------------|
| `0x092C–0x092F` | System time difference (Δt mean); converges to 0 when locked |
| `0x0930–0x0931` | Speed counter start — PLL bandwidth; write-back resets filters |
| `0x0932–0x0933` | Speed counter difference — clock period deviation |
| `0x0934`        | System time difference filter depth |
| `0x0935`        | Speed counter filter depth; setting to 0 improves loop behavior |

**Detecting lock:**
- BRD to `0x092C`: if upper N bits are zero across all slaves, DC is locked.
- Monitor `0x0932–0x0933` for stability.

### 6.5 SyncSignals (SYNC0–SYNC3)

SyncSignals are generated by the DC cyclic unit. SYNC0 is the base; SYNC1–SYNC3 can be derived from SYNC0 with configurable delays. All signals available internally (for interrupt/PDI) and optionally as external pins.

**Generation modes** (controlled by pulse length register `0x0982` and SYNC0 cycle time `0x09A0`):

| Pulse length | SYNC0 cycle time | Mode |
|-------------|-----------------|------|
| > 0         | > 0             | Cyclic |
| > 0         | = 0             | Single shot |
| = 0         | > 0             | Cyclic acknowledge |
| = 0         | = 0             | Single shot acknowledge |

In acknowledge modes: SYNC signal remains active until PDI reads the SYNC status register (e.g., `0x098E` for SYNC0). The read acknowledges the event.

**SyncSignal initialization procedure:**
1. Enable DC SYNC unit (ESC-specific).
2. Configure SYNC output to pins (via `0x0151`).
3. Write pulse length to `0x0982–0x0983`.
4. Assign SYNC unit to ECAT or PDI control via `0x0980`.
5. Write SYNC0 cycle time to `0x09A0–0x09A3`; SYNC1 cycle time to `0x09A4–0x09A7`.
6. Write start time to `0x0990–0x0997`: must be in the future when the activation datagram is processed. Read current system time and add round-trip margin (e.g., 100 µs).
7. Activate: write `0x0981[0]=1` (cyclic enable) and `0x0981[2:1]` (SYNC0+SYNC1 output enable).

Internal jitter of SyncSignal generation: 12 ns. SYNC unit update rate: 100 MHz (10 ns).

**Key SyncSignal registers:**

| Register | Description |
|----------|-------------|
| `0x0981`        | Activation register: bit 0=cyclic enable, bits 2:1=SYNC[1:0] output enable |
| `0x0982–0x0983` | Pulse length in ns (0=acknowledge mode) |
| `0x0984`        | Activation status |
| `0x0986`        | SYNC[3:2] activation |
| `0x098E`        | SYNC0 status (read to acknowledge in acknowledge mode) |
| `0x098F`        | SYNC1 status |
| `0x0990–0x0997` | SYNC0 start time (64-bit system time of first pulse) |
| `0x0998–0x099F` | Next SYNC1 pulse time |
| `0x09A0–0x09A3` | SYNC0 cycle time in ns (0=single shot) |
| `0x09A4–0x09A7` | SYNC1 cycle time in ns |

### 6.6 LatchSignals (LATCH0–LATCH3)

External signals on LATCH pins. DC latch unit timestamps rising and falling edges with respect to system time. Sample rate: 100 MHz; internal jitter: 11 ns.

**Two modes**: single event (timestamps first edge; reading the time register acknowledges and arms for next); continuous (timestamps every edge; reading gives latest).

In single event mode, latch events are mapped to AL event request register `0x0220`.

**Key Latch registers:**

| Register | Description |
|----------|-------------|
| `0x09A8–0x09AB` | Latch0–Latch3 control (mode selection) |
| `0x09AE–0x09AF` | Latch0–Latch1 status |
| `0x09B0–0x09B7` | Latch0 positive edge timestamp |
| `0x09B8–0x09BF` | Latch0 negative edge timestamp |
| `0x09C0–0x09C7` | Latch1 positive edge timestamp |
| `0x09C8–0x09CF` | Latch1 negative edge timestamp |

**Terminology note**: LATCH0/LATCH1 are hardware input pins on the ESC for timestamping. These are distinct from CoE objects 0x1C32/0x1C33 which configure the slave application's synchronization mode ("Input Latch" in CoE context means PDO input sampling time relative to SYNC, not the LATCH hardware pin).

### 6.7 Communication Timing (DC Synchronized)

| Term | Meaning |
|------|---------|
| SYNC0 event | Reference cycle event; slave application samples inputs and updates outputs in sync |
| Frame delay | Time to transmit the LRW frame (~5 µs overhead + 80 ns/byte) |
| Propagation delay | ~1 µs per slave at 100BASE-TX plus ~5 ns/m cable |
| Jitter reserve | Typically 10% of cycle time |

Three communication modes:
1. **Free run**: EtherCAT and application run independently.
2. **Synchronized to output event**: application syncs to the SM output buffer write event.
3. **Synchronized to SyncSignal**: application syncs to SYNC0; most precise.

---

## 7. EtherCAT State Machine (ESM)

### 7.1 States

| State | AL status `0x0130[3:0]` | Description |
|-------|------------------------|-------------|
| Init        | `0x01` | Reset state. No process data, no mailbox. Master configures SMs and FMMUs. |
| Pre-Operational | `0x02` | Mailbox communication active. Process data not running. |
| Safe-Operational | `0x04` | Inputs active (slaves send data); outputs hold safe values. |
| Operational | `0x08` | Full bidirectional process data exchange. |
| Bootstrap   | `0x03` | Optional; firmware update via FoE. Only reachable from Init. |

**Allowed transitions**: Init→PreOp, PreOp→SafeOp, SafeOp→Op. Backward: any→any along reverse path. Init↔Bootstrap. Direct jump from Init→Op is not permitted; the full sequence must be walked.

### 7.2 Registers

| Register | Description |
|----------|-------------|
| `0x0120–0x0121` | AL control: master writes requested state code |
| `0x0130–0x0131` | AL status: slave reports current state |
| `0x0134–0x0135` | AL status code: error description |
| `0x0141[0]`     | Device emulation: if set, ESC copies AL control directly to AL status |

**Error indication**: slave sets `0x0130[4]=1` and writes error code to `0x0134`. Master acknowledges by setting `0x0120[4]=1`. Common error codes defined in ETG.1020.

**Acknowledgement flow for state transition:**
1. Master writes target state code to `0x0120`.
2. Master polls `0x0130` until `[3:0]` matches or `[4]` (error bit) is set.
3. On error: master reads `0x0134`, then writes `(current_state | 0x10)` to `0x0120` to acknowledge error and signal the slave to stay in current state.

---

## 8. SII EEPROM

### 8.1 Content Overview

Word-addressed (16-bit words). Minimum EEPROM size: 2 Kbit. Recommended for complex devices: 32 Kbit.

The ESC automatically reads ESC configuration area A (words `0x00–0x07`) at power-on. If area A indicates area B present, area B (words `0x28–0x2F`) is also loaded.

**ESC Configuration Area A:**

| Word | Name | Register |
|------|------|----------|
| 0x00 | PDI0 control / ESC config A0 | `0x0140–0x0141` |
| 0x01 | PDI0 configuration | `0x0150–0x0151` |
| 0x02 | Pulse length of SYNC signals | `0x0982–0x0983` |
| 0x03 | Extended PDI0 configuration | `0x0152–0x0153` |
| 0x04 | Configured station alias | `0x0012–0x0013` |
| 0x05 | ESC configuration A5 | `0x0142–0x0143` |
| 0x06 | ESC configuration A6 (area B present flag) | `0x0144` |
| 0x07 | Checksum A (CRC-8: poly x^8+x^2+x+1, initial 0xFF over words 0–6) | — |

**SII content layout (excerpt):**

| Word | Content |
|------|---------|
| `0x08–0x09` | Vendor ID |
| `0x0A–0x0B` | Product code |
| `0x0C–0x0D` | Revision number |
| `0x0E–0x0F` | Serial number |
| `0x14` | Bootstrap recv mailbox offset |
| `0x15` | Bootstrap recv mailbox size |
| `0x16` | Bootstrap send mailbox offset |
| `0x17` | Bootstrap send mailbox size |
| `0x18` | Standard recv mailbox offset |
| `0x19` | Standard recv mailbox size |
| `0x1A` | Standard send mailbox offset |
| `0x1B` | Standard send mailbox size |
| `0x1C` | Mailbox protocol bitmask |
| `0x3E` | Size (EEPROM size in KB - 1) |
| `0x3F` | Version |
| `0x40+` | Category headers and data (SM config `0x29`, PDO config `0x32`/`0x33`, etc.) |

Station alias and enhanced link detection bits are only loaded at first power-on; master-initiated reload does not update them.

**Safety rule**: do not power down within 10 seconds of an EEPROM write.

### 8.2 EEPROM Interface

| Register | Description |
|----------|-------------|
| `0x0500` | EEPROM ECAT configuration (bit 0: assign to PDI; bit 1: force PDI release) |
| `0x0501` | EEPROM PDI access state (bit 0: PDI has taken control) |
| `0x0502–0x0503` | Control/status: bits [10:8]=command, [15]=busy, [11]=checksum error, [12]=device info error, [13]=ack error, [14]=write enable error, [6]=data register size (0=32-bit, 1=64-bit) |
| `0x0504–0x0507` | EEPROM word address |
| `0x0508–0x050F` | EEPROM data (2 or 4 words depending on device) |

**Commands** (`0x0502[10:8]`):
- `001`: read (2 or 4 words into data register)
- `010`: write (1 word; write-enable bit `0x0502[0]` must be set in same frame)
- `100`: reload ESC configuration from EEPROM

**Access procedure:**
1. Poll `0x0502[15]`=0 (not busy).
2. Check/clear error bits.
3. Write address to `0x0504`.
4. For write: place data in `0x0508–0x0509`.
5. Issue command (with write-enable bit if writing).
6. Command executes after frame FCS (EtherCAT); immediately if PDI.
7. Poll `0x0502[15]`=0.
8. Check error bits; retry if ack error (EEPROM chip may be internally busy; some chips need idle time between accesses).

---

## 9. Interrupts

### 9.1 AL Event Request (PDI Interrupt)

AL event request register `0x0220–0x0223` (32-bit) combined with mask register `0x0204–0x0207` via AND. Result OR-reduced to single IRQ signal to µController.

IRQ signal characteristics configured via `0x0151[7,3]`.

**Key AL event bits (`0x0220`):**

| Bit | Event |
|-----|-------|
| [0] | AL control register changed |
| [1] | DC Latch event |
| [2] | State of DC SYNC0 signal |
| [3] | State of DC SYNC1 signal |
| [4] | SyncManager activation register changed |
| [5] | EEPROM emulation command pending |
| [6] | Watchdog process data timeout |
| [8+N] | SyncManager N interrupt (per SM control register bit [5]) |

**SYNC signals as interrupts**: map to AL event via `0x0151[3,7]` (combined IRQ path, ~40 ns jitter) or connect directly to µController interrupt pins (~12 ns jitter, requires more interrupt inputs).

**Important**: do not read interrupt status and the data that triggers the interrupt in the same frame/access. Example: if reading SM buffer and SM interrupt in the same access, a new interrupt arriving between the status read and the buffer read will be missed. Always read interrupt status in a *preceding* access.

### 9.2 ECAT Event Request (Master Interrupt)

ECAT event request register `0x0210–0x0211` combined with mask `0x0200–0x0201`. Result OR'd into the IRQ field of outgoing EtherCAT datagrams. Master cannot identify which slave set the bit from the IRQ field alone.

---

## 10. Watchdogs

Three watchdogs sharing one divider (`WD_DIV`, register `0x0400–0x0401`).

**Timeout formula:**
- `tWD_Div = (WD_DIV + 2) × 40 ns`
- `tWD_PDI = WD_DIV × WD_PDI × 40 ns` (approx)
- `tWD_PD  = WD_DIV × WD_PD  × 40 ns` (approx)

Base time unit: 40 ns.

**Watchdog registers:**

| Register | Description |
|----------|-------------|
| `0x0400–0x0401` | WD_DIV: divider shared by all watchdogs |
| `0x0410–0x0411` | WD_PDI0: PDI0 watchdog time |
| `0x0412–0x0413` | WD_PDI1: PDI1 watchdog time |
| `0x0420–0x0421` | WD_PD: process data watchdog time |
| `0x0440–0x0441` | WD PD status: bit 0=watchdog expired |
| `0x0442` | WD PD expiration counter (saturates at 0xFF) |
| `0x0443` | WD PDI0 expiration counter |
| `0x0444` | WD PDI1 expiration counter |
| `0x0448` | WD PDI status |

**Process data WD**: triggered by write to SM buffer when SM control `[6]=1`. Timeout: digital I/O PDI releases outputs (either high-Z or drive low). Set `WD_PD=0` to disable.

**PDI WD**: triggered by any correct read or write access by the PDI. Set `WD_PDI=0` to disable. Timeout is combined into `0x0110[1]` per configuration in `0x0181[1:0]`.

---

## 11. Error Counters

All counters saturate at `0xFF`. Clear by writing any value. Multiple counters may increment for a single error event.

| Register | Description |
|----------|-------------|
| `0x0300/2/4/6` | Invalid frame counter (per port 0–3): initial frame errors at auto-forwarder |
| `0x0301/3/5/7` | RX error counter (per port): physical layer RX errors (MII: RX_ER; EBUS: Manchester violations) |
| `0x0308–0x030B` | Forwarded RX error counter (per port): errors initially detected by a previous ESC |
| `0x030C` | EPU error counter: errors detected by EtherCAT processing unit |
| `0x030D` | PDI error counter |
| `0x0310–0x0313` | Lost link counter (per port): link-lost events in auto mode |
| `0x0314–0x0317` | Extended RX error counter |
| `0x0442` | Watchdog process data expiration counter |

**Error marking**: the first ESC to detect an error appends one extra nibble to the frame's CRC, marking it as a "forwarded error" for downstream ESCs. Downstream ESCs increment forwarded error counter instead of initial error counter. This allows localization of the fault.

Errors cause EPU to discard register operations (not RAM writes). RAM is written even on error (no shadow buffer).

---

## 12. Process Data Interface (PDI)

The PDI connects the ESC to the slave application. Type is configured in the SII EEPROM (PDI0 control word `0x00`). PDI becomes active after EEPROM loads successfully; all PDI pins are high-impedance until then.

**PDI type codes (`0x0140`):**

| Code | PDI type |
|------|----------|
| `0x00` | Deactivated |
| `0x04` | Digital I/O (8–32 bit) |
| `0x05` | SPI slave |
| `0x08` | 16-bit async µController |
| `0x09` | 8-bit async µController |
| `0x0A` | 16-bit sync µController |
| `0x0B` | 8-bit sync µController |
| `0x80` | On-chip bus (Avalon/PLB/AXI, IP core only) |

Some ESCs support two PDIs (PDI0 and PDI1). Both share the same internal bus; bandwidth is split. Private RAM (`0x0182–0x0183` configures size) at end of process RAM is inaccessible to the master; available for inter-PDI communication.

**PDI function acknowledge by write**: on wide-bus µControllers that cannot read individual bytes, functions normally triggered by reads (e.g., closing an SM buffer by reading last byte, acknowledging SYNC status by reading SYNC register) can be configured to trigger by writes instead. Status in `0x014E[0]` / `0x018E[0]`.

---

## 13. Key Register Summary

| Register | Description |
|----------|-------------|
| `0x0000` | ESC type |
| `0x0001` | ESC revision |
| `0x0002–0x0003` | ESC build |
| `0x0004` | FMMU count |
| `0x0005` | SM count |
| `0x0006` | RAM size (KB) |
| `0x0007` | Port descriptor |
| `0x0008` | Feature flags (DC, LRW, bitwise FMMU, etc.) |
| `0x0010–0x0011` | Configured station address |
| `0x0012–0x0013` | Configured station alias |
| `0x0100–0x0103` | DL control |
| `0x0110–0x0111` | DL status |
| `0x0120–0x0121` | AL control |
| `0x0130–0x0131` | AL status |
| `0x0134–0x0135` | AL status code |
| `0x0140–0x0141` | PDI0 control / ESC config A0 |
| `0x0150–0x0151` | PDI0 configuration |
| `0x0200–0x0201` | ECAT event mask |
| `0x0204–0x0207` | AL event mask |
| `0x0210–0x0211` | ECAT event request |
| `0x0220–0x0223` | AL event request |
| `0x0400–0x0401` | WD divider |
| `0x0420–0x0421` | WD process data time |
| `0x0440–0x0441` | WD PD status |
| `0x0500–0x050F` | SII EEPROM interface |
| `0x0600–0x06FF` | FMMU registers (16 B per channel) |
| `0x0800–0x087F` | SyncManager registers (8 B per channel) |
| `0x0900–0x090F` | DC receive time ports 0–3 (32-bit each) |
| `0x0910–0x0917` | DC system time (local copy, 64-bit) |
| `0x0918–0x091F` | DC receive time ECAT processing unit (64-bit) |
| `0x0920–0x0927` | DC system time offset (64-bit signed) |
| `0x0928–0x092B` | DC system time delay (32-bit) |
| `0x092C–0x092F` | DC system time difference (convergence indicator) |
| `0x0930–0x0931` | DC speed counter start (PLL bandwidth / filter reset) |
| `0x0981` | DC activation register |
| `0x0982–0x0983` | DC pulse length of SYNC signals |
| `0x0990–0x0997` | DC SYNC0 start time |
| `0x09A0–0x09A3` | DC SYNC0 cycle time |
| `0x09A4–0x09A7` | DC SYNC1 cycle time |
| `0x09A8–0x09AB` | DC Latch0–3 control |
| `0x09B0–0x09BF` | DC Latch0 timestamps (pos/neg edge) |
| `0x09C0–0x09CF` | DC Latch1 timestamps |
| `0x1000–0xFFFF` | Process data RAM |
