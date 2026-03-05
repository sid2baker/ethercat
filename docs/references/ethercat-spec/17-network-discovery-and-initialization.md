# Network Discovery and Initialization

This is the exact sequence an LLM must implement to bring a raw EtherCAT network from darkness into the light of the Init state.
## Phase 1: The Call into the Void
When the network is first powered on, all slaves share the same physical ring, but none possess a name. The Master must first determine exactly how many slaves exist.
1. **The Broadcast:** The Master constructs a single frame containing a **Broadcast Read (BRD)** datagram.
2. **The Target:** The datagram targets a harmless, read-only register, typically the ESC Type register (`0x0000`).
3. **The Revelation:** The Master sends the frame. As it passes through every slave, each slave executes the read and increments the Working Counter (WKC).
4. **The Tally:** When the frame returns to the Master, the WKC contains the exact integer count of every active EtherCAT Slave Controller (ESC) on the network. The Master now knows the size of its slave set.
## Phase 2: The Naming
A Master cannot efficiently govern a network using only positional (Auto-Increment) addressing. It must assign a permanent **Configured Station Address** (Node ID) to each slave.
The Master loops through the known count of slaves (discovered in Phase 1) and executes the following:
1. **The Positional Command:** The Master crafts an **Auto-Increment Physical Write (APWR)** datagram targeting the Configured Station Address register (`0x0010:0x0011`).
2. **The Auto-Increment Math:** * To target the 1st slave in the ring, the Master sets the datagram's address to `0x0000`.
* To target the 2nd slave, it sets the address to `-1` (`0xFFFF`).
* To target the 3rd slave, it sets the address to `-2` (`0xFFFE`), and so on.
* *(Recall Book I: The slave increments the address as it passes. The slave that sees exactly `0x0000` is the one that processes the write).*
3. **The Assignment:** The data payload of this APWR is the new 16-bit Node ID chosen by the Master (e.g., `0x1001` for the first slave, `0x1002` for the second).
4. **Verification:** The Master checks the returning WKC. If WKC == 1, the slave has accepted its name.
From this moment on, the Master should cease using Auto-Increment addressing and communicate with each slave directly using **Configured Station Addressing (FPRD / FPWR)**.
## Phase 3: Topology Verification
Knowing the slaves exist is not enough; the Master must know how they are physically wired together to calculate Distributed Clocks delays later.
1. **Reading the Physical State:** The Master loops through every named slave using an FPRD command targeting the **DL Status register (`0x0110:0x0111`)**.
2. **Mapping the Ports:** By inspecting bits 4-15 of the DL Status, the Master determines exactly which of the four possible ports (Port 0 through Port 3) on each slave have an active physical link, and whether the internal loop is open or closed.
3. **Validating the Tree:** * Port 0 is always the "upstream" port pointing back toward the Master.
* If Port 1 has a link, another slave is connected downstream.
* If Port 1 is closed but Port 2 has a link, the topology branches (like in a junction module).
* By chaining these port states together, the Master builds an exact internal software model of the physical wiring tree.
## Phase 4: Clearing the Sins of the Past
Before proceeding to configure the slaves, the Master must ensure they are in a clean state, free from residual errors from a previous session.
1. **Resetting Errors:** The Master sends a Broadcast Write (BWR) to the AL Control register (`0x0120`), writing the command for the **Init** state (`0x01`) while simultaneously setting the **Error Acknowledge bit** (Bit 4) to `1` (writing `0x11`).
2. **Verifying Init:** The Master polls the AL Status register (`0x0130`) of all slaves to ensure every single node is safely resting in the Init state (`0x01`) with no error flags raised.