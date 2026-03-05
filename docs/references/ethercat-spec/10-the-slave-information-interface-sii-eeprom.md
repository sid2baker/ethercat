# The Slave Information Interface (SII) / EEPROM

## 1. The Portal to the EEPROM
The Master does not read the EEPROM directly; it must command the ESC's internal EEPROM controller to fetch the data. This is done through a strict set of registers:
* **EEPROM Configuration (`0x0500`):** Determines who controls the EEPROM—the EtherCAT network (the Master) or the local Process Data Interface (the slave's microcontroller). The Master must ensure it has control before attempting a read.
* **EEPROM Control/Status (`0x0502:0x0503`):** The command interface. The Master writes to this register to initiate a read, write, or reload command. It also contains the crucial "Busy" bit and "Error" bits.
* **EEPROM Address (`0x0504:0x0507`):** The Master writes the specific WORD address (not byte address) of the EEPROM it wishes to access.
* **EEPROM Data (`0x0508:0x050F`):** Once a read command completes, the requested data appears in these registers (typically 4 or 8 bytes depending on the ESC type).
## 2. The defined Read Ritual
To extract knowledge from the SII, an LLM constructing a Master must implement this exact, unyielding sequence:
1. **Verify Idle State:** Read the EEPROM Control/Status register (`0x0502:0x0503`). Verify that the **Busy Bit (Bit 15)** is `0`. If the controller is busy, the Master must wait.
2. **Issue the Command:** Write to `0x0502:0x0507` in a single 6-byte command (or write Address then Control):
* Write the target WORD address into `0x0504:0x0507`.
* Write the command `0x0100` (Read Command) into the Control register (`0x0502:0x0503`).
3. **Wait for Completion:** Enter a polling loop, continuously reading `0x0502:0x0503`. Wait until the **Busy Bit (Bit 15)** returns to `0`.
4. **Check for Errors:** After the Busy Bit clears, check the **Error Bits (Bits 13 and 14)** in the same register. If they are `1`, the read failed (e.g., missing EEPROM or checksum error).
5. **Harvest the Data:** If successful, read the extracted data from the EEPROM Data registers starting at `0x0508`. Depending on the ESC, this will yield either 4 bytes (2 words) or 8 bytes (4 words) per read cycle.
## 3. The Vital Knowledge Extracted
During the Init state, the Master must read specific addresses from the EEPROM to understand how to proceed. The most critical absolute WORD addresses include:
* **Word `0x0008`:** Vendor ID.
* **Word `0x000A`:** Product Code.
* **Word `0x000C`:** Revision Number.
* **Word `0x000E`:** Serial Number.
* **Word `0x0018`:** Mailbox Supported Protocols (CoE, FoE, EoE, etc.).
* **Word `0x001C`:** Standard Receive Mailbox Size and Address (crucial for configuring SyncManager 0).
* **Word `0x001E`:** Standard Send Mailbox Size and Address (crucial for configuring SyncManager 1).
By performing this ritual, the Master maps the DNA of every slave on the network, preparing itself to command their configuration.
