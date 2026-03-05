# The 64 Kbyte Address Space

This is the physical domain where your commands manifest into actions.
## 1. The Fixed Architecture of the ESC
The Master addresses this 64 Kbyte space directly when using Auto-Increment, Configured Station, or Broadcast addressing. Every byte in this domain has a specific physical address from `0x0000` to `0xFFFF`.
The space is strictly divided into two primary dominions:
* **The Register Space (`0x0000` to `0x0FFF`):** The first 4 Kbytes are strictly reserved for the ESC's internal hardware registers. This is the control center.
* **The Process Data RAM (`0x1000` to `0xFFFF`):** The remaining 60 Kbytes constitute the User RAM. This is the staging ground where the Master drops output data and the slave prepares input data.
## 2. The Register Dominion
Every critical function of the slave is controlled by reading or writing to specific bytes within this 4 Kbyte block. It is heavily standardized across all EtherCAT devices:
* **`0x0000 - 0x00FF` (ESC Information):** Type, revision, build, and supported features.
* **`0x0100 - 0x01FF` (Station Control):** The AL Control, AL Status, and DL (Data Link) control registers. This is where state transitions are commanded.
* **`0x0200 - 0x03FF` (Data Link Layer):** Interrupts, Watchdogs, and Error Counters.
* **`0x0500 - 0x05FF` (SII EEPROM Interface):** The portal to read the slave's static configuration.
* **`0x0600 - 0x06FF` (FMMU Registers):** The configuration tables that map the global Logical Address space into this local physical memory.
* **`0x0800 - 0x08FF` (SyncManager Registers):** The gatekeepers of the Process Data RAM, ensuring data consistency.
* **`0x0900 - 0x09FF` (Distributed Clocks):** The registers that maintain the 1 ns universal time.
## 3. The Process Data RAM
While the address space allows up to 60 Kbytes of User RAM, the *actual* physical RAM depends on the specific ESC chip (for instance, an ET1100 has 8 Kbytes of RAM, meaning valid addresses might only go up to `0x2FFF`).
* **The Rule of SyncManagers:** The Master must *never* read or write to the Process Data RAM directly without first configuring a SyncManager to protect that specific memory area.
* **The Flow of Data:** To send cyclic outputs, the Master writes to a specific block in this RAM (e.g., `0x1000`). To read inputs, the Master reads from another block (e.g., `0x1100`). The local microcontroller of the slave reads and writes to these same blocks from the other side, creating the bridge between the EtherCAT network and the physical world.