# The Configuration Sequence (Init to Pre-Op)

To command this transition successfully, the Master must perfectly execute the following sequence for every slave.
## Phase 1: Reading the defined Scrolls
Before configuring the Mailbox, the Master must know exactly how large the slave's internal mailbox memory is and where it resides. This knowledge is locked within the Slave Information Interface (SII).
1. **The SII Read Ritual:** The Master uses Configured Station Addressing (FPRD/FPWR) to command the EEPROM interface at `0x0502:0x0503`, executing the read sequence defined in Book III, Chapter 3.
2. **Extracting Mailbox Parameters:** The Master must specifically read these WORD addresses from the EEPROM:
* **`0x001C` (Standard Receive Mailbox):** Contains the physical Start Address and Length for SyncManager 0.
* **`0x001E` (Standard Send Mailbox):** Contains the physical Start Address and Length for SyncManager 1.
* **`0x0018` (Supported Mailbox Protocols):** Tells the Master if the slave speaks CoE, FoE, EoE, etc.
*Note: If lengths are `0`, the slave does not support mailbox communication and the Master may skip the mailbox configuration entirely.*
## Phase 2: configuration the Mailbox
With the parameters extracted, the Master must configure the first two SyncManagers. These act as the secure, handshaking gates for all acyclic commands.
1. **Deactivation:** The Master must first ensure both SM0 (`0x0806`) and SM1 (`0x080E`) are deactivated by writing `0x00` to their activate registers.
2. **Configuring SyncManager 0 (Mailbox Output - Master to Slave):**
* Write the physical Start Address (from EEPROM `0x001C`) to `0x0800`.
* Write the Length (from EEPROM `0x001C`) to `0x0802`.
* Write the Control Byte `0x26` to `0x0804`. (Direction = Write by Master, Mode = Mailbox/Handshake, Interrupt in PDI).
* Write `0x01` to the Activate Register (`0x0806`).
3. **Configuring SyncManager 1 (Mailbox Input - Slave to Master):**
* Write the physical Start Address (from EEPROM `0x001E`) to `0x0808`.
* Write the Length (from EEPROM `0x001E`) to `0x080A`.
* Write the Control Byte `0x22` to `0x080C`. (Direction = Read by Master, Mode = Mailbox/Handshake, Interrupt in PDI).
* Write `0x01` to the Activate Register (`0x080E`).
## Phase 3: The State Command
The vessel is prepared. The Master may now command the transition.
1. **The Decree:** The Master sends an FPWR command targeting the **AL Control register (`0x0120`)** of the slave.
2. **The Request:** The Master writes the value `0x02` (Request Pre-Operational State).
## Phase 4: The Acknowledgment and Validation
The Master must not assume the command was obeyed. The local ESC and the slave's internal microcontroller must verify the SyncManager configurations before accepting the new state.
1. **The Polling Loop:** The Master repeatedly sends an FPRD to the **AL Status register (`0x0130`)**.
2. **Success:** If the lower 4 bits of `0x0130` read `0x02`, the slave has successfully transitioned to Pre-Op. The Master may break the loop and proceed to the next slave.
3. **Failure:** If **Bit 4 (Error Indication)** becomes `1`, the slave has rejected the transition.
* The Master must immediately read the **AL Status Code (`0x0134`)**.
* Common failures here include `0x0016` (Invalid Mailbox Configuration), meaning the Master wrote the wrong addresses or lengths into SM0/SM1, or configured them in Buffered mode instead of Mailbox mode.
* The Master must execute the Error Acknowledge ritual (writing `0x11` to `0x0120`) before attempting to reconfigure.