# Principles of DC Synchronization

## 1. The Universal Time System
EtherCAT does not rely on the Master's operating system timer, which is often flawed by jitter. Instead, it relies on strict hardware clocks built directly into the silicon of the EtherCAT Slave Controllers (ESCs).
* **The Resolution:** The EtherCAT system time is a 64-bit variable that increments in units of exactly **1 nanosecond**.
* **The Epoch:** The universal zero-point (Epoch) for this timer is January 1, 2000, at 00:00:00.
* **The Scale:** A 64-bit counter at 1 ns resolution holds enough time to run continuously for over 500 years without overflowing. The lower 32 bits wrap around roughly every 4.29 seconds and are primarily used for fast, cyclic sync events.
## 2. The Reference Clock
The Master itself is *not* the source of time. The network jitter between the Master's software and the Ethernet port makes it an unworthy timekeeper.
* **The Election:** The Master must elect one slave on the network to be the **Reference Clock**. By strict convention, this is the very first slave in the physical ring topology that supports Distributed Clocks functionality.
* **Master tasks:** The Master's true role is not to generate the time, but to act as the messenger. The Master must cyclically read the 64-bit time from the Reference Clock and distribute it to every other slave in the network.
## 3. The Three Pillars of Synchronization
To ensure every slave shares the exact same nanosecond despite being separated by physical distance and varied hardware, the Master must calculate and compensate for three distinct variables:
1. **Initial Offset:** When slaves power on, their internal timers start at zero. The Reference Clock might be at 100 seconds, while Slave 2 is at 5 seconds. The Master must calculate this absolute difference and write an **Offset** into Slave 2's registers so that `Local Time + Offset = System Time`.
2. **Propagation Delay:** Light in a copper cable takes time to travel (roughly 5 ns per meter), and passing through a slave's hardware takes time. If the Master broadcasts the Reference Time, it will arrive at Slave 10 slightly later than it arrived at Slave 2. The Master must calculate exactly how long the wire and hardware delays are between nodes and write this **Transmission Delay** into each slave.
3. **Drift Compensation:** No two quartz crystals oscillate at the exact same frequency. Over time, Slave 2's clock will drift away from the Reference Clock. The Master must continuously send a cyclic broadcast frame containing the Reference Time. The local ESC hardware uses this cyclic frame to dynamically speed up or slow down its internal clock, maintaining lock-step precision.
## 4. The Core DC Registers
The Master controls this strict synchronization by manipulating the registers in the `0x0900` range of the ESC:
* **`0x0900` (Receive Time Port 0):** Hardware latch that captures the exact local time a frame arrived. Used for delay calculations.
* **`0x0910:0x0917` (System Time):** The current 64-bit synchronized time.
* **`0x0920:0x0927` (System Time Offset):** The calculated difference between the local timer and the Reference Clock.
* **`0x0928:0x092B` (System Time Delay):** The calculated physical propagation delay to this specific slave.