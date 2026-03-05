# SyncManagers (0x0800+)

## 1. The Guardians of Consistency
The SyncManager is a hardware mechanism within the EtherCAT Slave Controller (ESC) that regulates concurrent access to the physical RAM. The EtherCAT network (the Master) accesses the memory from one side, while the local application (the Process Data Interface, or PDI) accesses it from the other.
Without a SyncManager, the Master might overwrite a block of data exactly while the slave is reading it, causing a fatal mix of old and new data. The SyncManager mathematically guarantees consistency.
## 2. The Two Modes of Operation
The Master must configure each SyncManager to operate in one of two distinct modes, depending on the nature of the data:
* **Mailbox Mode (Handshake):**
* **Mechanism:** Uses a single memory buffer. It enforces a strict handshake: the producer writes the data, locking the buffer. The consumer then reads the data, unlocking the buffer.
* **Rule:** The producer cannot write new data until the consumer has read the old data.
* **Purpose:** Exclusively used for acyclic communication (like CoE or FoE) during Pre-Op, Safe-Op, and Op states. It guarantees that absolutely no messages are dropped or overwritten.
* **Buffered Mode (3-Buffer):**
* **Mechanism:** Uses three rotating memory buffers managed entirely in hardware.
* **Rule:** The producer can *always* write the latest data, and the consumer can *always* read the latest consistent data. They never block each other.
* **Purpose:** Exclusively used for cyclic Process Data Objects (PDOs). In real-time control, receiving the *latest* data is more important than receiving *every single* intermediate data frame.
## 3. The Four Standard Messengers
While an ESC can support up to 16 SyncManager channels (determined by reading register `0x0005`), the EtherCAT specification heavily standardizes the first four:
* **SyncManager 0 (SM0): Mailbox Output.** Configured in Handshake mode. The Master writes acyclic data here; the slave reads it.
* **SyncManager 1 (SM1): Mailbox Input.** Configured in Handshake mode. The slave writes acyclic responses here; the Master reads them.
* **SyncManager 2 (SM2): Process Data Output.** Configured in Buffered mode. The Master writes cyclic setpoints and commands here.
* **SyncManager 3 (SM3): Process Data Input.** Configured in Buffered mode. The slave writes cyclic sensor readings and actual values here.
## 4. The Configuration Ritual
To breathe life into a SyncManager, the Master must program its specific 8-byte control block. For SyncManager $n$, the base address is `0x0800 + (n * 8)`.
The Master must configure the following registers for each active SyncManager:
* **Physical Start Address (`+0x0`, 2 Bytes):** Where in the physical RAM (`0x1000` - `0xFFFF`) this SyncManager's buffer begins.
* **Length (`+0x2`, 2 Bytes):** The total size of the buffer in bytes.
* **Control Register (`+0x4`, 1 Byte):** * Bits 0-1: Direction (00 = Read by Master, 01 = Write by Master).
* Bits 2-3: Mode (00 = Buffered/3-Buffer, 10 = Mailbox/Handshake).
* Bit 4: Interrupt in DDI/EtherCAT (Master) side.
* Bit 5: Interrupt in PDI (Slave) side.
* Bit 6: Watchdog Enable (Crucial for SM2 Process Data Outputs; if the Master stops sending, the watchdog triggers a drop to Safe-Op).
* **Activate Register (`+0x6`, 1 Byte):** The Master writes `0x01` (Bit 0) to officially activate the SyncManager channel.
*Implementation Warning:* A SyncManager can only be reconfigured or activated if the Master first deactivates it by writing `0x00` to its Activate Register.