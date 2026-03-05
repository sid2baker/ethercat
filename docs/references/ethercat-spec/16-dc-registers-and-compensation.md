# DC Registers and Compensation (0x0900+)

## 1. The Initial Offset
When the slaves awaken, their internal 64-bit timers start counting from zero independently. Before the Master can demand synchronized action, it must align all slaves to the exact time of the chosen Reference Clock.
* **The Snapshot:** The Master reads the current 64-bit time from the Reference Clock (typically the first DC-capable slave).
* **The Calculation:** For every other slave, the Master calculates the difference between the Reference Clock's time and the slave's local time.
* **The System Time Offset (`0x0920:0x0927`):** The Master writes this calculated difference into this 64-bit register. The ESC hardware then continuously calculates the true System Time using this strict formula:
$$System\_Time = Local\_Timer + System\_Time\_Offset + System\_Time\_Delay$$
*(Where the Delay is the propagation value calculated in Chapter 2, stored in `0x0928`)*.
## 2. The Drift Compensation
Time is an illusion that frays at the edges. The quartz crystals driving the ESCs are rated in parts-per-million (ppm). Over minutes, one slave's clock will drift microseconds away from the Reference Clock. The Master must enforce discipline continuously.
* **The Speed Counter (`0x0930:0x0931`):** The ESC hardware monitors the drift by comparing its internal clock speed against the frequency of the arriving reference time frames.
* **The Filter Depth (`0x0934`):** The Master configures a hardware filter to smooth out network jitter, ensuring the slave does not overcorrect.
* **The Hardware Magic:** Once configured, the drift compensation is handled entirely by the ESC hardware. If the slave detects it is running faster than the reference time, it mathematically slows down its local timer increments. If it is lagging, it speeds them up. The Master's only duty is to ensure the reference time arrives cyclically.
## 3. The Cyclic DC Ritual
To keep the drift compensation loops locked, the Master must embed a specific time-keeping datagram into its cyclic Process Data transmission (usually at the very beginning of the frame).
This is executed using a single, powerful command: **ARMW (Auto-Increment Read Multiple Write)** or a combination of **FPRD** and **BWR**.
1. **The Read:** The Master addresses the System Time register (`0x0910:0x0913`) of the Reference Clock.
2. **The Write:** As the frame continues through the network, that exact 32-bit timestamp (the lower half of the 64-bit time) is written to the Receive Time register (`0x0900`) of every subsequent slave.
3. **The Lock:** The internal hardware of the slaves instantly compares this arriving time with their own predicted System Time, feeding the error into their internal drift compensation PI-controller.
## 4. SYNC Out and LATCH In
Once the internal System Time is perfectly synchronized across the network (typically locked to $< 100 \text{ ns}$ deviation), the Master can command the physical hardware.
* **SYNC Signals:** The Master configures the SYNC registers (`0x0980` - `0x09A7`) to generate physical electrical pulses on the slave's internal pins at exact, pre-defined System Times. This tells a motor drive exactly when to apply the current, or an output terminal exactly when to switch its relay.
* **LATCH Signals:** Conversely, if an external sensor detects an event, the LATCH pins instantly record the exact 64-bit System Time of that event into the Latch registers (`0x09A8` - `0x09B7`), allowing the Master to know precisely when the physical world changed.
