# The ESM Architecture

The state of an EtherCAT slave is governed by the ESM, which dictates exactly which communication functions are currently permitted. The master requests state changes, and the slave must acknowledge them.
There are four primary states of operational existence, and one state reserved for rebirth (firmware updates).
## 1. The Init State
This is the default state immediately after power-on.
* **Capabilities:** Neither Mailbox (acyclic) nor Process Data (cyclic) communication is possible. The master can only communicate via direct register access using Auto-Increment or Configured Station addressing.
* **Master tasks:** In this state, the Master must assign the Configured Station Address (`0x0010`) and initialize the Mailbox SyncManagers (typically SM0 and SM1). Once the mailbox is configured, the Master may command the transition to Pre-Operational.
## 2. The Pre-Operational State
The slave has initialized to asynchronous communication.
* **Capabilities:** Mailbox communication is now fully active, allowing protocols like CoE (CAN application protocol over EtherCAT) to be used. Process Data communication remains inactive.
* **Master tasks:** This is the era of configuration. The Master uses the Mailbox to read the slave's object dictionary, perform dynamic PDO mapping (if supported), and configure the slave's specific application parameters. The Master also programs the FMMUs and the Process Data SyncManagers (typically SM2 and SM3).
## 3. The Safe-Operational State
Cyclic communication starts in this state. The network begins its cyclic exchange, but with strict safety limits.
* **Capabilities:** Both Mailbox and Process Data communication are active. However, the slave keeps its physical outputs in a "safe state" (they are not driven by the master's data). The slave *does* cyclically update its physical inputs, allowing the Master to read the current state of the sensors/hardware.
* **Master tasks:** The Master must begin transmitting valid cyclic Process Data (Logical ReadWrite frames) at the expected interval. To transition to the final state, the Master must send valid output data so the slave has correct values ready the moment it switches over.
## 4. The Operational State
Full closed-loop operation between master and slave.
* **Capabilities:** Full operational capability. Mailbox communication remains active, Process Data inputs are updated, and the slave now actively copies the cyclic Process Data outputs received from the Master to its physical hardware outputs.
* **Master tasks:** The Master maintains the cyclic transmission, continuously evaluating the Working Counters to ensure the link remains unbroken. If synchronization or data flow fails, the slave will automatically fall back to Safe-Op to protect the physical world.
## 5. The Bootstrap State
Firmware update state.
* **Capabilities:** This state can *only* be reached directly from the Init state. No Process Data communication is possible, and standard Mailbox communication is heavily restricted. Only the File Access over EtherCAT (FoE) protocol is permitted.
* **Master tasks:** The Master uses this state exclusively to download new firmware or complete EEPROM structures to the slave.