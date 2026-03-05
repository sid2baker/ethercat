# Process Data Objects (PDO) Mapping

## 1. The Nature of Process Data Objects
While the EtherCAT hardware sees only raw bytes and bits, the application sees variables: a 16-bit temperature reading, a 32-bit position target, or an 8-bit status word. These variables are packed into Process Data Objects.
From the perspective of the Master:
* **RxPDO (Receive PDO):** Data received by the slave. These are the Master's **Outputs** (e.g., target velocity, control words).
* **TxPDO (Transmit PDO):** Data transmitted by the slave. These are the Master's **Inputs** (e.g., actual position, status words).
## 2. The Two Layers of Organization
To construct the process image, the Master must understand two distinct mapping structures within the slave's CoE Object Dictionary. This is typically read from the ESI (EEPROM) or dynamically via Mailbox (SDO) communication during the Pre-Operational state.
* **Layer 1: PDO Mapping (The Contents)**
* This defines exactly which application variables are packed into a single PDO.
* **RxPDOs** are defined in Object Dictionary indices `0x1600` to `0x17FF`.
* **TxPDOs** are defined in indices `0x1A00` to `0x1BFF`.
* *Example:* The Master reads index `0x1A00` and discovers it contains two objects: a 16-bit Status Word and a 32-bit Actual Position. The total size of this TxPDO is 48 bits (6 bytes).
* **Layer 2: PDO Assignment (The Guardians)**
* This defines which PDOs are assigned to which SyncManager.
* The Master looks at the SyncManager Communication Type objects, specifically **`0x1C12` (RxPDO assign for SM2)** and **`0x1C13` (TxPDO assign for SM3)**.
* *Example:* The Master reads `0x1C13` and sees it lists PDO `0x1A00` and PDO `0x1A01`.
## 3. Constructing the Master's Process Image
During the Pre-Operational state, the Master must perform the defined calculus of the Process Image:
1. **Calculate the Total Size:** The Master traverses the assignments in `0x1C12` and `0x1C13`. It sums the bit-lengths of every mapped variable inside every assigned PDO.
2. **Configure the SyncManagers:** The calculated total output size (in bytes, rounded up) becomes the `Length` parameter for SyncManager 2 (`0x0812`). The total input size becomes the `Length` for SyncManager 3 (`0x081A`).
3. **Configure the FMMUs:** The Master allocates a block of its own global Logical Memory. It then programs the FMMUs (as detailed in Book IV, Chapter 2) to map this logical block to the physical bounds governed by SM2 and SM3.
4. **Byte and Bit Alignment:** EtherCAT does not mandate standard byte alignment. If a slave maps a 1-bit boolean followed by a 16-bit integer, the integer will start on bit 1, heavily misaligned. The Master's internal software must be mathematically precise, extracting variables using exact bit-offsets calculated during the mapping phase.
## 4. Dynamic vs. Static Mapping
* **Static Mapping:** Many simple I/O terminals have a fixed PDO structure described in their EEPROM. The Master simply reads it and configures the FMMUs.
* **Dynamic Mapping:** Advanced drives (like servo motors) allow the Master to rewrite indices `0x1600+` and `0x1A00+` via the Mailbox in Pre-Op state. The Master commands the slave to assemble a custom PDO containing only the exact variables the Master desires, optimizing network bandwidth before transitioning to Safe-Op.
