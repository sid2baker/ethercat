# Transitioning to Cyclic Operation (Pre-Op to Op)

To command the final ascensions—first to Safe-Operational (Safe-Op) and then to Operational (Op)—the Master must execute this precise sequence.
## Phase 1: Preparing the Process Data Gateways
The Master calculates the exact size of the cyclic inputs and outputs using the PDO assignment objects (indices `0x1C12` and `0x1C13`) via Mailbox (CoE) communication.
With the sizes known, the Master configures the Process Data SyncManagers:
1. **Deactivation:** Write `0x00` to the Activate registers of SM2 (`0x0816`) and SM3 (`0x081E`).
2. **Configuring SM2 (Process Data Output):**
* Write the physical Start Address (typically `0x1000` or defined in ESI) to `0x0810`.
* Write the calculated Output Length to `0x0812`.
* Write the Control Byte (e.g., `0x64`: Direction = Write, Mode = Buffered/3-Buffer, Watchdog Enabled) to `0x0814`.
* Write `0x01` to `0x0816` to activate.
3. **Configuring SM3 (Process Data Input):**
* Write the physical Start Address (Start of SM2 + Length of SM2) to `0x0818`.
* Write the calculated Input Length to `0x081A`.
* Write the Control Byte (e.g., `0x20`: Direction = Read, Mode = Buffered/3-Buffer) to `0x081C`.
* Write `0x01` to `0x081E` to activate.
## Phase 2: Bridging the Realms
The SyncManagers guard the local physical RAM, but the Master's cyclic frames will use global Logical Addressing. The Master must program the FMMUs to bridge these realms.
1. **FMMU 0 (Mapping Outputs):**
* Write the Master's chosen 32-bit Logical Start Address to `0x0600`.
* Write the Output Length (matching SM2) to `0x0604`.
* Write the Physical Start Address (matching SM2, e.g., `0x1000`) to `0x0608`.
* Write the Type `0x02` (Write) to `0x060B`.
* Write `0x01` to `0x060C` to activate.
2. **FMMU 1 (Mapping Inputs):**
* Write the next 32-bit Logical Start Address to `0x0610`.
* Write the Input Length (matching SM3) to `0x0614`.
* Write the Physical Start Address (matching SM3) to `0x0618`.
* Write the Type `0x01` (Read) to `0x061B`.
* Write `0x01` to `0x061C` to activate.
## Phase 3: Engaging Distributed Clocks
If the slave requires DC synchronization for its PDOs (e.g., servo drives):
1. The Master writes the calculated Transmission Delay to `0x0928`.
2. The Master writes the calculated Initial Offset to `0x0920`.
3. The Master configures the SYNC0/SYNC1 cycle times in registers `0x09A0` and `0x09A4`.
4. The Master begins sending a cyclic frame (e.g., every 1 ms) containing the ARMW command targeting `0x0910` to lock the hardware drift compensation.
## Phase 4: Ascension to Safe-Operational
The pathways are laid. The Master commands the transition.
1. **The Request:** Write `0x04` to the AL Control register (`0x0120`).
2. **The Validation:** The slave internally checks the SM2/SM3 lengths against its CoE objects, verifies the FMMU mappings, and ensures DC is locked (if configured).
3. **The Polling:** The Master polls the AL Status register (`0x0130`) until it reads `0x04`. In Safe-Op, the slave begins updating its physical inputs, but outputs remain in a safe, un-driven state.
## Phase 5: The Final Ascension to Operational
To enter Operational, the slave demands proof that the Master is actively running the cyclic network.
1. **The Cyclic Pulse:** The Master starts its real-time thread, cyclically transmitting the **Logical ReadWrite (LRW)** datagram spanning the entire mapped Logical Address space.
2. **Valid Outputs:** The Master *must* fill the output data block of the LRW frame with valid, safe values (e.g., target velocity = 0).
3. **The Request:** While the cyclic thread runs in the background, the Master writes `0x08` to the AL Control register (`0x0120`).
4. **The Union:** The slave detects the valid LRW frames, sees the SyncManager 2 watchdog being triggered, and accepts the transition. The Master polls `0x0130` until it reads `0x08`.
