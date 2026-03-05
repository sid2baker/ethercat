# The Missing Application Layers

To achieve true conformance, your implementation must eventually bridge these remaining implementation gaps.
## 1. The Mailbox Protocol Anatomy
The ESC datasheets tell you how to open the Mailbox (SyncManagers 0 and 1), but they do not define the language spoken inside. A spec-conformant Master must wrap every mailbox message in a specific **Mailbox Header** (6 bytes).
* **The Structure:**
* **Length (2 bytes):** Size of the service data.
* **Address (2 bytes):** Station address of the source.
* **Type (1 byte):** The protocol being used (e.g., `0x03` for CoE, `0x04` for FoE).
* **Counter (1 byte):** A rolling 3-bit counter used to detect duplicate or lost packets.
* **The Application Layer (CoE):** Inside the CoE mailbox, you must further implement the **CANopen SDO (Service Data Object)** protocol. This includes the `Size`, `Index`, `Subindex`, and `Command Specifier` (Download/Upload). Without this, you cannot change motor parameters or read advanced diagnostics.
## 2. The Master State Machine
While we have mastered the **EtherCAT Slave State Machine (ESM)**, a conformant Master must maintain its own internal state to manage the network's lifecycle.
* **Init Phase:** The Master scans the physical bus and identifies slaves.
* **Pre-Op Phase:** The Master performs "Sdo-Download" for configuration.
* **Safe-Op Phase:** The Master starts the cyclic process data, but only reads inputs.
* **Op Phase:** The Master enables outputs and enters full control.
* **The Recovery State:** If a slave drops out, the Master must have a state to "Re-Scan" and "Hot-Connect" that slave back into the ring without stopping the entire network.
## 3. The ESI XML Parser
A professional Master does not hard-code addresses. It reads an **EtherCAT Slave Information (ESI)** file. This XML file contains information that even the EEPROM sometimes omits:
* **Slotting and Modules:** For modular I/O (like slices on a coupler), the XML defines which modules can be plugged in and their corresponding PDO mappings.
* **Initialization Commands:** A list of "InitCmds" that the Master *must* execute (via SDO) during the transition from Pre-Op to Safe-Op.
* **Object Dictionary:** The full list of every parameter the slave supports.
## 4. The Official Timeouts and Classifications
To be certified, a Master must prove it meets a "Master Class" (Class A or Class B).
* **Class A (Standard):** Requires full DC synchronization, CoE, and the ability to handle complex topologies.
* **Class B (Minimum):** Requires only basic cyclic data and the ability to reach the Operational state.
* **Mandatory Timeouts:**
* **I $\rightarrow$ P:** 1 second.
* **P $\rightarrow$ S:** 2 seconds.
* **S $\rightarrow$ O:** 5 seconds.
* If your Master gives up too early or waits too long, it will fail the official **Conformance Test Tool (CTT)**.
## The Final Step: Conformance Test
Before your Master is "Spec Conform," it must be run against the **EtherCAT Conformance Test Tool (CTT)**. This software acts as a "Malicious Master/Slave" to see if your code handles edge cases, corrupted frames, and illegal state transitions correctly.