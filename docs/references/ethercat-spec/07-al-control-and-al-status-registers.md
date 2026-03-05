# AL Control and AL Status Registers

## 1. The AL Control Register
This 16-bit register is the Master's steering wheel for the EtherCAT State Machine. It is written by the Master and read by the EtherCAT Slave Controller (ESC).
To request a state change or acknowledge an error, the Master writes to the lower byte (`0x0120`). The bit anatomy is as follows:
* **Bits 0-3 (State Request):** The Master writes the exact code of the desired state.
* `0x1` (0001): Request **Init** State
* `0x2` (0010): Request **Pre-Operational** State
* `0x3` (0011): Request **Bootstrap** State
* `0x4` (0100): Request **Safe-Operational** State
* `0x8` (1000): Request **Operational** State
* **Bit 4 (Error Acknowledge):** If the slave is in an error state, the Master must set this bit to `1` while simultaneously writing the current actual state in bits 0-3 to clear the error.
* **Bit 5 (Device Identification):** If set to `1`, the Master requests the slave to load its specific Device ID into the AL Status register (used in specific hot-connect scenarios).
* **Bits 6-15:** Reserved. The Master should write `0` to these bits.
## 2. The AL Status Register
This 16-bit register is the slave's voice. It is written by the ESC hardware and microcontroller, and read by the Master to verify the current state and detect faults.
The lower byte (`0x0130`) mirrors the structure of the AL Control register, but reflects the *actual* condition of the slave:
* **Bits 0-3 (Actual State):** The current ESM state of the slave.
* `0x1`: **Init**
* `0x2`: **Pre-Operational**
* `0x3`: **Bootstrap**
* `0x4`: **Safe-Operational**
* `0x8`: **Operational**
* **Bit 4 (Error Indication):** If `1`, the slave has encountered an error and cannot process the last state request, or it has spontaneously dropped to a lower state due to a fault (like a SyncWatchdog timeout).
* **Bit 5 (Device Identification):** If `1`, indicates the Device ID is valid and loaded.
* **Bits 6-15:** Reserved.
## 3. The AL Status Code Register
When the slave raises the Error Indication flag (Bit 4 of `0x0130`), the Master must immediately read this 16-bit register to understand *why* the slave is displeased.
Common critical error codes include:
* `0x0011`: Invalid requested state change.
* `0x0012`: Unknown requested state.
* `0x0016`: Invalid mailbox configuration.
* `0x001D`: Invalid output configuration (e.g., FMMU or SyncManager setup is wrong).
* `0x002B`: Process Data Watchdog timeout (the Master stopped sending cyclic data).
## 4. The Master's Execution Logic
When a Master commands a state transition (e.g., moving from Pre-Op to Safe-Op), the code must execute this strict sequence:
1. **Write:** Send an FPRW or FPWR to `0x0120` with the value `0x04` (Safe-Op).
2. **Poll:** Continuously send FPRD to `0x0130` (AL Status) in a loop.
3. **Evaluate:** Mask the returned byte with `0x0F` (Bits 0-3).
* If the result is `0x04`, the transition is successful. Break the loop.
* If Bit 4 (mask `0x10`) is `1`, an error occurred. Break the loop, read `0x0134` for the error code, and execute the Error Acknowledge ritual.
4. **Timeout:** If neither success nor error occurs within the mandated timeout window (typically several seconds depending on the slave), abort the transition and flag a timeout error.
