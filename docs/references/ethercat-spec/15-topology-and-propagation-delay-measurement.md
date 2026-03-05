# Topology and Propagation Delay Measurement

## 1. The Logical Ring and the Turning Point
To understand the measurement, you must understand the journey of the frame. EtherCAT relies on a full-duplex physical layer (like 100BASE-TX) operating as a logical ring.
* **The Forward Path:** A frame enters a slave through Port 0. The FMMUs and SyncManagers process it on the fly, and it is forwarded out through Port 1 to the next slave.
* **The Auto-Close:** If a slave has no cable plugged into Port 1 (it is the last node on the branch), its hardware automatically "closes" the port.
* **The Return Path:** The frame turns around internally and travels backward through the network, passing through the identical slaves in reverse order until it returns to the Master.
Because the frame travels both forward and backward, the Master can measure the exact round-trip time.
## 2. The Port Timestamps
Every EtherCAT Slave Controller (ESC) equipped with Distributed Clocks has a set of dedicated hardware latches. The moment the first bit of an Ethernet frame arrives at a physical port, the hardware stamps that exact local time into a 32-bit register.
* **Port 0 Receive Time (`0x0900:0x0903`)**
* **Port 1 Receive Time (`0x0904:0x0907`)**
* **Port 2 Receive Time (`0x0908:0x090B`)**
* **Port 3 Receive Time (`0x090C:0x090F`)**
*Note:* Because Port 0 is always the entry point towards the Master, the time stamped in `0x0900` is the absolute local arrival time of the Master's command.
## 3. The Measurement Ritual
During the Pre-Operational state, before activating the cyclic sync, the Master executes this precise sequence to map the network's spatial delays:
1. **The Broadcast Trigger:** The Master sends a Broadcast Write (BWR) to register `0x0900` across the entire network. The actual data written does not matter; the act of addressing this register commands every ESC to latch its local port timestamps for *this exact frame*.
2. **The Harvest:** The Master loops through every slave using Configured Station Addressing (FPRD). It reads the timestamps from all active ports (reading `0x0900` through `0x090F`).
3. **The Topology Mapping:** By comparing which ports have timestamps and which are zero, the Master perfectly reconstructs the physical wiring of the network—knowing exactly which slave is plugged into which port of another slave.
## 4. The Math of the Delay
Once the Master has harvested the timestamps, it must calculate the **Propagation Delay (`0x0928:0x092B`)** for every node.
* **Calculating the Slave's Internal Delay:** If a slave has nodes connected behind it (e.g., active on Port 0 and Port 1), the frame entered Port 0, traveled down the network, and returned to Port 1.
* *Delay behind the slave* = `Time at Port 1` - `Time at Port 0`.
* **Calculating the Absolute Cable Delay:** By starting at the Reference Clock (the first DC slave) and working backward/forward through the tree, the Master subtracts the "delay behind the slave" to isolate the exact nanoseconds lost in the physical copper cables between each node.
* **The Final Decree:** The Master calculates the cumulative physical delay from the Reference Clock to each individual slave. It then writes this 32-bit value into the slave's **System Time Delay Register (`0x0928:0x092B`)**.
When the local ESC computes the synchronized System Time, it will automatically add this `0x0928` delay to compensate for its physical distance from the Reference Clock.