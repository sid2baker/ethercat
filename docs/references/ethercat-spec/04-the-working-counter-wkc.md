# The Working Counter (WKC)

## 1. The Mechanism of Validation
* Every EtherCAT datagram ends with a 16-bit Working Counter (WKC).
* As the datagram passes through the network, the Working Counter counts the number of devices that were successfully addressed by this specific datagram.
* "Successfully" means that the EtherCAT Slave Controller (ESC) was addressed correctly and the addressed memory was accessible (for example, a protected SyncManager buffer).
* EtherCAT slave controllers increment this counter directly in hardware, completely independent of the slave's microcontroller or software.
* The Master is required to calculate the expected Working Counter value for every datagram it sends. Upon receiving the returned frame, the Master compares the actual WKC with the expected WKC to verify valid processing.
## 2. Increment Rules and Calculation
The working counter is increased if at least one byte or one bit of the whole multi-byte datagram was successfully read and/or written. (Note: For a multi-byte datagram, the Master cannot tell from the WKC alone if all or only one byte was successfully processed, allowing separated register areas to be read using a single datagram by ignoring unused bytes).
The hardware increments the WKC according to strict mathematical rules based on the command type:
* **Read Commands (APRD, FPRD, BRD, LRD):**
* No success: No change.
* Successful read: +1.
* **Write Commands (APWR, FPWR, BWR, LWR):**
* No success: No change.
* Successful write: +1.
* **Read-Write Commands (APRW, FPRW, BRW, LRW):**
* No success: No change.
* Successful read: +1.
* Successful write: +2.
* Successful read and write: +3.
* **Special Cases (ARMW, FRMW):** * The Auto-Increment/Configured Address Physical Read Multiple Write commands are evaluated depending on their address match. They are either treated completely like a read command (+1 on success) or completely like a write command (+1 on success).
## 3. Handling WKC Failures
If the returned WKC does not match the master's calculated expectation, the data within that datagram must not be trusted. For cyclic process data (Logical ReadWrite - LRW), an invalid WKC usually means a slave dropped off the network or lost synchronization, requiring the master to discard the inputs and potentially trigger the EtherCAT state machine error handling routines.
**Which Book or Chapter shall I reveal next?** (e.g., "Book II, Chapter 1" to learn of the EtherCAT State Machine architecture).