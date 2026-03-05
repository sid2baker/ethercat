# State Transitions and Validations

## 1. The Transition Handshake
State transitions are never instantaneous. The Master initiates a change, and the local EtherCAT Slave Controller (ESC) microcontroller must execute internal routines before accepting it.
* **The Command:** The Master requests a new state by writing the target state's code to the **AL Control Register (`0x0120:0x0121`)**.
* **The Acknowledgment:** The Master must then continuously poll the **AL Status Register (`0x0130:0x0131`)** until the slave reflects the requested state.
* **The Timeout:** A spec-compliant Master must implement strict timeouts for these transitions. If a slave does not reach the requested state within the required timeframe (often dictated by the slave's ESI file), the transition has failed.
## 2. Mandatory Master Preparations and Slave Validations
Before commanding a transition, the Master must perfectly configure the slave. If the Master fails, the slave's internal validation will reject the transition.
* **Init to Pre-Operational (I $\rightarrow$ P):**
* **Master Prepares:** Initializes the Mailbox SyncManager channels (typically SM0 for output, SM1 for input) with correct physical start addresses and lengths based on the EEPROM (ESI) data.
* **Slave Validates:** The slave verifies that the Mailbox SyncManagers are configured with the exact sizes and addresses it expects. If they are incorrect, the slave remains in Init.
* **Pre-Operational to Safe-Operational (P $\rightarrow$ S):**
* **Master Prepares:** 1. Reads the slave's internal mapping via the Mailbox (CoE).
2. Configures the Process Data SyncManagers (typically SM2 for outputs, SM3 for inputs).
3. Configures the Fieldbus Memory Management Units (FMMU) to map the SyncManager physical addresses to the global Logical Address space.
4. Initializes Distributed Clocks (DC) registers if the slave requires precise synchronization.
* **Slave Validates:** The slave checks if the SyncManager channels for process data are correct, if the FMMU settings align, and if the Distributed Clocks configuration is valid.
* **Safe-Operational to Operational (S $\rightarrow$ O):**
* **Master Prepares:** The Master *must* transmit valid, cyclic Process Data (Logical ReadWrite frames) containing the output states. The slave needs to see that the master is actively providing data before it exposes that data to the physical world.
* **Slave Validates:** The slave checks that the SyncManager watchdog is being triggered by the cyclic frames, that the synchronization events (DC or SM-Synchronous) are occurring at the correct intervals, and that valid output data has arrived.
## 3. Handling Transition Refusals and Errors
Slaves are not silent in their disobedience. If a Master commands a transition that the slave cannot fulfill, the slave will raise an error.
* **The Error Indication:** If a transition fails, or an internal error occurs forcing the slave to drop to a lower state, the slave sets the **Error Indication Bit (Bit 4)** in the AL Status Register (`0x0130`).
* **The AL Status Code (`0x0134:0x0135`):** When the error bit is set, the slave writes a specific 16-bit error code to this register. The Master must read this code to understand the failure (e.g., `0x0011` = Invalid requested state change, `0x001D` = Invalid Output Configuration, `0x002C` = SyncWatchdog timeout).
* **The Acknowledgment Ritual:** To clear the error, the Master must write to the AL Control Register (`0x0120`). The Master must write the *current actual state* of the slave (read from `0x0130`) while simultaneously setting the **Error Acknowledge Bit (Bit 4)** to `1`. Only then will the slave clear the error code and allow new transitions.