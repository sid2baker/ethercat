# The Four Pillars of Addressing

## 1. Auto-Increment Addressing
Before a slave has a name (a configured address), it has a position. Auto-Increment addressing allows the Master to address slaves based strictly on their physical order in the network ring.
* **The Mechanism:** The Master places a negative 16-bit address (e.g., `0x0000`, `0xFFFF` for -1, `0xFFFE` for -2) in the datagram's address field. As the frame passes through each EtherCAT Slave Controller (ESC), the slave increments this value by 1.
* **The Execution:** The slave that reads the address as exactly `0x0000` after incrementing it is the target. It executes the command and sets the Working Counter. Subsequent slaves ignore it.
* **The Purpose:** This pillar is used exclusively during network startup to scan the topology, count the number of connected slaves, and assign them their permanent Configured Station Addresses.
* **The Commands:**
* **APRD:** Auto-Increment Physical Read
* **APWR:** Auto-Increment Physical Write
* **APRW:** Auto-Increment Physical ReadWrite
## 2. Configured Station Addressing
Once the Master has discovered the network, it assigns a unique 16-bit address (Node ID) upon each slave by writing to register `0x0010:0x0011`.
* **The Mechanism:** The Master places the exact 16-bit Station Address of the target slave in the datagram. The frame passes through the ring, and only the slave whose internal register (`0x0010`) matches this address will process the command.
* **The Purpose:** This is the primary method for acyclic communication. The Master uses it to read and write specific slave configurations, monitor errors, and exchange Mailbox data (such as CoE - CAN application protocol over EtherCAT, or FoE - File Access over EtherCAT) during the Pre-Operational, Safe-Operational, and Operational states.
* **The Commands:**
* **FPRD:** Configured Address Physical Read
* **FPWR:** Configured Address Physical Write
* **FPRW:** Configured Address Physical ReadWrite
## 3. Logical Addressing
This is the most powerful addressing mode, designed for the high-speed operation of cyclic Process Data. Instead of addressing a single slave, Logical Addressing addresses a large, 4 Gigabyte virtual memory space shared by the entire network.
* **The Mechanism:** The datagram contains a 32-bit Logical Address. As the frame passes through a slave, the slave's Fieldbus Memory Management Unit (FMMU) acts as a hardware translator. The FMMU checks if the logical address falls within its configured mapping window. If it does, the FMMU instantly reads from or writes to the passing frame, mapping the data directly to its internal physical RAM.
* **The Power:** A single logical datagram can read inputs from and write outputs to *dozens* of slaves simultaneously. The frame is not delayed; the data is inserted and extracted on the fly.
* **The Purpose:** Used strictly for cyclic Process Data Objects (PDO) exchange during Safe-Operational and Operational states.
* **The Commands:**
* **LRD:** Logical Read (Master reads inputs from slaves)
* **LWR:** Logical Write (Master writes outputs to slaves)
* **LRW:** Logical ReadWrite (Master reads inputs and writes outputs simultaneously in one frame)
## 4. Broadcast Addressing
There are times when the Master must speak to all slaves at once.
* **The Mechanism:** The Master uses a specific broadcast command. Every slave in the network that supports the command will process it, executing the instruction and modifying the datagram's Working Counter.
* **The Purpose:** Broadcasts are used to initialize states, read collective status (e.g., "Are there any errors in the network?"), or distribute the Distributed Clocks reference time to all nodes simultaneously.
* **The Commands:**
* **BRD:** Broadcast Read
* **BWR:** Broadcast Write
* **BRW:** Broadcast ReadWrite