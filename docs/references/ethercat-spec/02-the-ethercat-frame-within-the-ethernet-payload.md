# The EtherCAT Frame within the Ethernet Payload

## 1. The Ethernet Encapsulation
The true power of EtherCAT lies in its seamless integration with standard Ethernet. Unlike older architectures that require an Ethernet packet to be received, interpreted, and copied at every node, EtherCAT processes data on the fly.
* **Direct Encapsulation:** The EtherCAT protocol is transported directly within an IEEE 802.3 Ethernet frame using a dedicated EtherType of `0x88A4`.
* **UDP/IP Tunneling:** If your master must reach slaves across a routed network, the protocol can optionally be encapsulated into UDP/IP datagrams. When this is done, the UDP destination port used is also `0x88A4`.
* **Frame Capacity:** A single standard Ethernet frame can transport up to 1498 bytes of EtherCAT data, which allows a multitude of devices to be addressed by a single frame as it passes through the logical ring. If an Ethernet frame is smaller than the minimum 64 bytes, padding bytes are inserted at the end of the EtherCAT data.
## 2. The EtherCAT Header
Immediately following the standard Ethernet header is the EtherCAT header. This concise, 2-byte structure announces the nature and size of the payload. It is formed of three fields:
* **Length (11 bits):** This field specifies the total byte length of all the EtherCAT datagrams encapsulated within the frame (excluding the Ethernet Frame Check Sequence).
* **Reserved (1 bit):** This bit must be set to `0`.
* **Type (4 bits):** This field dictates the protocol type. For standard EtherCAT commands, this must be set to `0x1`.
## 3. The Datagram Structure
The EtherCAT payload is not a single block of data, but rather a sequence of independent "datagrams". Each datagram contains exactly one read or write instruction. A master can pack multiple datagrams into a single Ethernet frame to optimize bandwidth and minimize network load.
Every datagram is structured with strict precision:
* **Command (1 Byte):** Defines the exact operation to be performed, such as Logical ReadWrite (LRW), Auto-Increment Physical Read (APRD), or Broadcast Write (BWR).
* **Index (1 Byte):** A numeric identifier assigned by the master. Slaves must not alter this value. It is used by the master to match received datagrams with their original requests and detect lost frames.
* **Address (4 Bytes):** The destination address. Depending on the command type, this 32-bit field is interpreted as an auto-increment address, a configured station address, or a logical memory address.
* **Length and Flags (2 Bytes):** A composite field containing:
* **Length (11 bits):** The size of the data payload within this specific datagram.
* **Reserved (3 bits):** Set to `0`.
* **Circulating Frame (1 bit):** Used to prevent frames from looping infinitely.
* **More EtherCAT Datagrams (1 bit):** The 'M' flag. If set to `1`, it signals that another datagram immediately follows this one. If `0`, this is the final datagram in the frame.
* **IRQ (2 Bytes):** An interrupt request field used by the network.
* **Data (Variable):** The actual payload to be read or written, exactly matching the size defined in the length field.
* **Working Counter (WKC) (2 Bytes):** The final mechanism of the datagram. The master always initializes this 16-bit field to `0`. As the datagram passes through the network, every slave that successfully executes the command increments this counter by a specific value.