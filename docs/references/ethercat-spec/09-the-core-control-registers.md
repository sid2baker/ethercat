# The Core Control Registers

## 1. The ESC Information
At the very startup of the address space lies the slave's immutable hardware identity.
* **ESC Type (`0x0000`):** Indicates the specific EtherCAT controller chip or IP core (for example, `0x11` designates an ET1100, while `0x02` designates an ESC20).
* **ESC Revision (`0x0001`) and Build (`0x0002:0x0003`):** Provides the exact hardware or firmware versioning of the slave controller.
* **FMMUs and SyncManagers Supported (`0x0004` and `0x0005`):** Read-only registers that reveal exactly how many FMMU and SyncManager channels the specific slave possesses in hardware.
## 2. The Station Addresses
This is where the Master assigns the slave's identity for direct acyclic addressing.
* **Configured Station Address (`0x0010:0x0011`):** The Master writes a unique 16-bit address here during network startup. This address is exclusively used for node addressing commands like Configured Address Physical Read (FPRD) and Write (FPWR).
* **Configured Station Alias (`0x0012:0x0013`):** An optional secondary address, typically loaded automatically from the EEPROM upon power-on. The Master can activate the use of this alias for FPRD/FPWR commands via a specific bit in the DL Control register.
## 3. Data Link (DL) Control
This powerful 32-bit register controls the physical layer and the flow of frames through the EtherCAT processing unit.
* **Forwarding Rule (Bit 0):** Dictates whether non-EtherCAT Ethernet frames are forwarded through the ring without processing or if they are destroyed.
* **Port Loop Configuration (Bits 8-15):** Controls the loop behavior of Ports 0 through 3, using 2 bits per port. The master can configure a port to "Open" (forward frames), "Closed" (turn frames around), or "Auto" (automatically close the loop when the link goes down to maintain ring continuity).
* **Station Alias Activation (Bit 24):** If set to `1`, the Station Alias register (`0x0012:0x0013`) is enabled and can be used for configured address commands.
## 4. Data Link (DL) Status
The voice of the physical network layer, providing vital diagnostics to the Master.
* **EEPROM Loaded / PDI Operational (Bit 0):** If this bit is `0`, the EEPROM has not loaded, the Process Data Interface (PDI) is not operational, and the Master cannot access the Process Data RAM. The master must verify this bit becomes `1`.
* **Physical Link and Communication Status (Bits 4-15):** Provides independent diagnostic flags for each port (0-3). It indicates if a physical link is detected, whether the internal loop is currently open or closed, and if stable communication is established on that specific port. By reading these bits, the Master maps out the exact physical topology and instantly detects broken cables or disconnected nodes.