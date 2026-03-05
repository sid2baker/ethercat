# Fieldbus Memory Management Units (FMMU) (0x0600+)

## 1. The Power of Logical Addressing
During the cyclic heartbeat (Safe-Op and Op states), the Master stops talking to individual slaves. Instead, it visualizes the entire network as one colossal, 4 Gigabyte shared memory space—the **Logical Address Space**.
The Master sends a single datagram (e.g., a Logical ReadWrite - LRW) addressed to a specific block within those 4 Gigabytes.
The FMMU is a hardware chip inside the EtherCAT Slave Controller (ESC). As the Master's frame flies through the slave, the FMMU continuously monitors the Logical Address in the datagram. If the address falls within the FMMU's configured "window," the FMMU instantly snatches data from the frame and writes it to the slave's Physical RAM, or copies data from the Physical RAM and inserts it into the passing frame—all with zero routing delay.
## 2. The feature of Bit-Level Mapping
The true strict power of the FMMU is that it does not just map bytes; it maps *bits*.
If you have eight separate digital input terminals, each producing exactly 1 bit of data, you do not need to waste 8 full bytes in your EtherCAT frame. You can configure the FMMU of Slave 1 to write to Bit 0 of Logical Address `0x00010000`, the FMMU of Slave 2 to write to Bit 1 of that same address, and so on. The master will receive a single, perfectly packed byte containing the states of all eight separate slaves.
## 3. The Configuration Ritual
An ESC can support up to 16 FMMU channels. Each FMMU is configured using a strict 16-byte register block. For FMMU $n$, the base address is `0x0600 + (n * 16)`.
To map a logical space to the physical RAM, the Master must perfectly program these fields:
* **Logical Start Address (`+0x0`, 4 Bytes):** The 32-bit address in the Master's global 4GB space where this mapping begins.
* **Length (`+0x4`, 2 Bytes):** The number of bytes this mapping covers.
* **Logical Start Bit (`+0x6`, 1 Byte):** The specific starting bit (0-7) within the first logical byte.
* **Logical Stop Bit (`+0x7`, 1 Byte):** The specific ending bit (0-7) within the last logical byte.
* **Physical Start Address (`+0x8`, 2 Bytes):** The 16-bit address in the ESC's local RAM (`0x1000` - `0xFFFF`) where the data actually resides. This *must* match the Physical Start Address of the corresponding SyncManager!
* **Physical Start Bit (`+0xA`, 1 Byte):** The starting bit (0-7) in the physical RAM.
* **Type (`+0xB`, 1 Byte):** Dictates the permitted access:
* `0x01`: Read (Slave to Master - Inputs)
* `0x02`: Write (Master to Slave - Outputs)
* `0x03`: Read/Write
* **Activate (`+0xC`, 1 Byte):** Writing `0x01` enables the FMMU.
## 4. The Master's Implementation Rule
A Master must configure the FMMUs during the **Pre-Operational state**, before attempting to transition to Safe-Operational.
The logical flow for an LLM generating this code is:
1. Identify the SyncManagers used for Process Data (usually SM2 for Outputs, SM3 for Inputs).
2. For the Output data, allocate a 32-bit Logical Address in the Master's internal memory map.
3. Configure FMMU 0 to map that 32-bit Logical Address to the 16-bit Physical Address of SM2. Set Type to `0x02` (Write).
4. For the Input data, allocate the next 32-bit Logical Address.
5. Configure FMMU 1 to map that Logical Address to the 16-bit Physical Address of SM3. Set Type to `0x01` (Read).
6. Activate both FMMUs.