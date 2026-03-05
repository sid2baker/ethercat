# The Continuous Loop

To sustain the Operational state, a spec-compliant Master must implement a continuous loop, typically divided into a strict Real-Time (Cyclic) Thread and a lower-priority Background (Acyclic) Thread.
## 1. The Real-Time Tick
The cyclic thread is governed by a strict, high-precision timer (e.g., 1 ms, 500 µs, or even 50 µs cycle time) running on the Master's operating system.
When the timer ticks, the Master must immediately execute this sequence:
1. **Update Outputs:** The Master's application logic calculates the new target values (e.g., motor positions, valve states) and writes them into the Master's internal Logical Memory map.
2. **Construct the Frame:** The Master packs these outputs into a single Ethernet frame containing the **Logical ReadWrite (LRW)** datagram(s) covering the entire mapped Process Data space. If Distributed Clocks are active, the Master prepends the **ARMW** (or FPRD/BWR) datagram to distribute the Reference Time.
3. **Transmit:** The frame is dispatched to the Network Interface Card (NIC).
4. **Wait and Receive:** The Master waits for the frame to traverse the logical ring and return. Because EtherCAT processes on the fly, this delay is purely the propagation time of the wire plus minimal hardware delays (typically just a few microseconds).
5. **Extract Inputs:** The Master extracts the updated sensor data (e.g., actual positions, physical inputs) that the slaves inserted into the LRW datagram on the fly.
## 2. The Working Counter (WKC) Evaluation
Extracting the inputs is not enough. The Master *must never* trust the returned data blindly. The physical world is unpredictable, and cables can be severed.
1. **Calculate the Expected WKC:** The Master knows exactly how many slaves are mapped to the LRW datagram. It calculates the expected WKC (e.g., +3 for every slave that both reads its outputs and writes its inputs).
2. **Compare:** The Master checks the actual WKC returned at the end of the LRW datagram.
3. **Success condition:** If `Actual WKC == Expected WKC`, the cycle is valid. The Master passes the extracted input data to the application logic to calculate the next cycle's outputs.
4. **Failure condition:** If the WKC mismatches, a slave has failed to process the data (due to lost synchronization, hardware fault, or disconnection). The Master **must** discard the input data for this cycle and hold the outputs steady. If the WKC fails for multiple consecutive cycles, the Master must alert the application and drop the affected slaves back to Safe-Op.
## 3. The Asynchronous Mailbox
While the real-time thread handles the cyclic heartbeat, a Master often needs to send occasional, non-time-critical commands—such as reading an error log from a slave or dynamically changing a tuning parameter via CoE (CAN application protocol over EtherCAT).
This is handled by a separate, lower-priority background thread:
1. **Polling the Mailbox:** Because slaves cannot initiate communication, the Master must periodically poll the slaves to see if they have asynchronous data waiting.
2. **Checking SM1 Status:** The Master sends an **FPRD** to read the state of SyncManager 1 (Mailbox Input) on the target slave.
3. **Extracting the Message:** If the SM1 status indicates data is waiting, the Master sends another **FPRD** to read the actual mailbox buffer (e.g., starting at `0x1080` if configured there).
4. **Sending a Command:** If the Master needs to write a parameter, it waits until SyncManager 0 (Mailbox Output) is free, then sends an **FPWR** containing the CoE SDO (Service Data Object) download command.
5. **Interleaving:** Crucially, these acyclic datagrams (FPRD/FPWR) can be appended to the end of the very same Ethernet frame that carries the cyclic LRW datagram, maximizing bandwidth efficiency without disrupting the real-time timing.
## 4. Continuous Diagnostics
In the background, the Master should periodically poll the **AL Status (`0x0130`)** and **DL Status (`0x0110`)** of the network. If a slave spontaneously drops from Op to Safe-Op (e.g., due to a SyncWatchdog timeout), the Master must detect this in the background thread, read the AL Status Code (`0x0134`), and attempt to acknowledge the error and re-establish the Operational state.