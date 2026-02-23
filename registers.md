## Version 3.

## Date: 2025- 07 -

# Hardware data sheet section II

# slave controller

# Section I – Technology

# (Online at http://www.beckhoff.com)

# Section II – Register description

# Register overview and detailed

## description

# Section III – Hardware description

## (Online at http://www.beckhoff.com)


##### DOCUMENT ORGANIZATION

II- II slave controller – register description

##### DOCUMENT ORGANIZATION

The Beckhoff EtherCAT slave controller (ESC) documentation covers the following Beckhoff ESCs:

- ET
- ET1100, ET
- EtherCAT IP core for FPGAs
- ESC

The documentation is organized in three sections. Section I and section II are common for all Beckhoff
ESCs, section III is specific for each ESC variant.

The latest documentation is available at the Beckhoff homepage (http://www.beckhoff.com).

**Section I – Technology (all ESCs)**

Section I deals with the basic EtherCAT technology. Starting with the EtherCAT protocol itself, the
frame processing inside EtherCAT slaves is described. The features and interfaces of the physical
layer with its two alternatives Ethernet and EBUS are explained afterwards. Finally, the details of the
functional units of an ESC like FMMU, SyncManager, distributed clocks, slave information interface,
interrupts, watchdogs, and so on, are described.

Since section I is common for all Beckhoff ESCs, it might describe features which are not available in
a specific ESC. Refer to the feature details overview in section III of a specific ESC to find out which
features are available.

**Section II – Register description (all ESCs)**

Section II contains detailed information about all ESC registers. This section is also common for all
Beckhoff ESCs, thus registers, register bits, or features are described which might not be available in
a specific ESC. Refer to the register overview and to the feature details overview in section III of a
specific ESC to find out which registers and features are available.

**Section III – Hardware description (specific ESC)**

Section III is ESC-specific and contains detailed information about the ESC features, implemented
registers, configuration, interfaces, pinout, usage, electrical and mechanical specification, and so on.
Especially the process data interfaces (PDI) supported by the ESC are part of this section.

**Additional documentation**

Application notes and utilities can also be found at the Beckhoff homepage. Pinout configuration tools
for EtherCAT ASICs are available. Additional information on EtherCAT IP cores with latest updates
regarding design flow compatibility, FPGA device support and known issues are also available.

**Trademarks**
Beckhoff®, ATRO®, EtherCAT®, EtherCAT G®, EtherCAT G10®, EtherCAT P®, MX-System®, Safety over EtherCAT®, TC/BSD®,
TwinCAT®, TwinCAT/BSD®, TwinSAFE®, XFC®, XPlanar®, and XTS® are registered trademarks of and licensed by Beckhoff
Automation GmbH. Other designations used in this publication may be trademarks whose use by third parties for their own
purposes could violate the rights of the owners.

**Disclaimer**
The documentation has been prepared with care. The products described are, however, constantly under development. For that
reason, the documentation is not in every case checked for consistency with performance data, standards or other
characteristics. In the event that it contains technical or editorial errors, we retain the right to make alterations at any time and
without warning. No claims for the modification of products that have already been supplied may be made on the basis of the
data, diagrams and descriptions in this documentation.

**Copyright**
© Beckhoff Automation GmbH & Co. KG 07/2025.
The reproduction, distribution and utilization of this document as well as the communication of its contents to others without
express authorization are prohibited. Offenders will be held liable for the payment of damages. All rights reserved in the event of
the grant of a patent, utility model or design.


##### DOCUMENT HISTORY

```
slave controller – register description II- III
```
##### DOCUMENT HISTORY

```
Version Comment
1.0 Initial release
```
1.1 (^) • LATCH0/1 state register bit 0x09AE[2] and 0x09AF[2] added (ET1100 and IP
core)

- On-chip bus configuration for Avalon®: extended PDI configuration register
    0x0152[1:0] added

1.2 (^) • On-chip bus configuration: extended PDI configuration register 0x0152[1:0] now
valid for both Avalon and OPB

- ESC DL status: PDI watchdog status constantly 1 for ESC
- EEPROM control/status: selected EEPROM Algorithm not readable for
    ESC10/

1.3 (^) • EEPROM/PHY management interface: Added self-clearing feature of command
register

- SPI extended configuration (0x0152:0x0153): reset value is EEPROM word A3,
    not word A
- ESC DL control (0x0100[0]): Added details about source MAC address change
- Power-on values ET1100 (0x0E000): P_CONF does not correspond with
    physical ports

1.4 (^) • Sync/latch PDI configuration register: latch configuration clarified

- AL control register: mailbox behavior described
- Editorial changes

1.5 (^) • ESC DL control (0x0100:0x0103): FIFO size description enhanced

- IP core: extended features (reset value of user RAM 0x0F80:0x0FFF) added
- PHY management interface: write access by PDI is only possible for ET1100 if
    Transparent mode is enabled. Corrected register read/write descriptions.
- PHY management control/status register (0x0510:0x0511): error bit description
    clarified. Write enable bit is self-clearing.
- ESC DL control (0x0100:0x0103): Temporary setting DL not available for
    ESC10/
- EEPROM PDI access state register (0x0501): write access depends on
    EEPROM configuration
- EEPROM control/status register (0x0502:0x0503): error bit description clarified.
    Write enable bit is self-clearing.
- Registers initialized from EEPROM have reset value 0, and EEPROM value
    after EEPROM was loaded successful
- AL event request (0x0220:0x0223) description clarified: SyncManager
    configuration changed interrupt indicates activation register changes.
- DC LATCH0/1 status (0x09AE:0x09AF): event flags are only available in single
    event mode
- DC SYNC0 cycle time (0x09A0:0x09A3): value of 0 selects single pulse
    generation
- 64 bit receive time ECAT processing unit (0x0918:0x091F) is also available for
    32 bit DCs. Renamed register to receive time ECAT processing unit
- RAM size (0x0006) ET1200: 1 Kbyte
- Editorial changes


##### DOCUMENT HISTORY

II- IV slave controller – register description

```
Version Comment
```
1.6 (^) • EEPROM control/status register (0x0502:0x0503): error bit description clarified

- EEPROM interface and PHY management interface: access to special registers
    is blocked while interface is busy
- EEPROM interface: EEPROM emulation by PDI added
- Extended IP core features (0x0F80:0x0FFF): reset values moved to section III
- Reset values of DC receive time registers are undefined
- MI control/status register bit 0x510[7] is read only
- FMMUs supported (0x0004): ET1200 has 3 FMMUs, not 4
- AL event request register: SyncManager changed flag (0x220[4]) is not
    available in IP core versions before and including 1.1.1/1.01b
- Configured station alias (0x0012:0x0013) is only taken over at first EEPROM
    load after power-on or reset
- Moved available PDIs depending on ESC to section I
- SyncManager PDI control (0x807 etc.): difference between read and write
    access described
- General purpose I/O registers (0x0F10:0x0F1F) width variable (1/2/4/8 byte)
- PHY management interface enhancement: link detection and assignment to PDI
    added
- Write access to DC time loop control unit by PDI configurable for IP core
    (V2.0.0/2.00a)
- Editorial changes

1.7 (^) • PHY management control/status (0x0510) updated: PHY address offset is 5
bits, feature bits have moved

- System time register (0x0910:0x0917): clarified functionality
- Process data RAM (0x1000 ff.): accessible only if EEPROM is loaded
- Digital I/O extended configuration (0x0152:0x0153): Set to 0 in bidirectional
    mode
- Editorial changes

1.8 (^) • DC register accessibility depends on DC power saving settings in PDI control
register (0x0140[11:10])

- AL event request register (0x0220): AL control event (bit 0) is cleared by
    reading AL control register (0x0120), not AL event request register
- EEPROM control/status register bit 0x0502[ 12 ] renamed to EEPROM loading
    status
- Description of push-pull/open-drain output drivers for SPI, μController, and
    SYNC0/1 enhanced
- Speed counter start register (0x0930:0x0931): write access resets calculated
    time loop control values
- Speed counter diff register (0x0932:0x0933): deviation calculation added
- DC start time cyclic operation (0x0990:0x0997) and next SYNC1 pulse
    (0x0998:0x099F) relate to the system time
- Reset DC control loop (write 0x0930:0x0931) after changing filter depths
    (0x0934 or 0x0935)
- Editorial changes

1.9 (^) • Update to EtherCAT IP core release 2.2.0/2.0 2 a

- Register availability added
- Writing to DC filter depth registers 0x0934:0x0935 resets filters
- DC activation register (0x0981) enhanced
- DC activation state register (0x0984) added
- Reserved registers or register bits: write 0, ignore read values
- Enhanced link detection 0x0141[1] has compatibility issues with EBUS ports,
    not MII ports
- port dependent enhanced link detection (0x0140[15:12] added
- PHY port y status bit 5 added (port configuration updated)
- ESC10 removed
- Editorial changes


##### DOCUMENT HISTORY

```
slave controller – register description II- V
```
```
Version Comment
```
2.0 (^) • DC Sync activation register (0x0981[6]): bit polarity corrected

- Deviation calculation formula for speed counter diff register (0x0932:0x0933)
    corrected
- AL event mask register (0x0204:0x0207): corresponding to AL event request
    register bits, not to ECAT event request register bits
- Register availability noted in ESC availability tabs
- Register digital I/O configuration (0x0150): corrected OUTVALID mode = 1
    description
- Power-on values ET1200 (0x0E00[6]): CLK25OUT on PDI[6], not PDI[31]
- Editorial changes

2.1 (^) • Register bit 0x0220[4] is not available for ESC

- DC system time (0x0910:0x0917): read value differs between ECAT and PDI
- DC latch times and DC event times are internally latched when lowest byte is
    read
- DC speed counter start (0x0930:0x0931): minimum value is 0x
- Editorial changes

2.2 (^) • ESC20: register configured station alias (0x0012:0x0013) is taken over after
each EEPROM reload command

- PHY management control register 0x0510[0]: updated to ET1100- 0002
- Registers 0x0020 and 0x0030 are readable for ET1100 and ET
- Editorial changes
2.3 • Update to EtherCAT IP core release 2.3.0/2.03a (registers 0x0138/0x0139,
0x0150 on-chip bus, 0x0220, 0x030E, 0x0805 affected)
- Separated registers 0x0140 (PDI control) and 0x0141 (now: ESC configuration)
- Editorial changes

2.4 (^) • ESC DL control register (0x0100[0]) description changed

- Added ESC feature bits 0x0008[11:9]
- Update to EtherCAT IP core release 2.3.2/2.03c
- ESC features 0x0008 and ESC configuration A0 0x0141[1]: enhanced link
    detection must not be activated for ET1100/ET1200 if EBUS ports are used.
- Editorial changes

2.5 (^) • Update to EtherCAT IP core release 2.4.0/2.04a

- ESC20: 0x0140[1:0] and [5:4] are available for SPI PDI
- Range for DC speed counter start (0x0930:0x0931) and speed counter diff
    (0x0932:0x0933) corrected, representation of speed counter diff mentioned.

2. (^6) • Update to EtherCAT IP core release 3.0.

- Added register DC receive time latch mode 0x
- Device identification in AL control/status register 0x0120/0x0130 added
- Editorial changes
2.7 • Update to EtherCAT IP core release 2.4.3/2.04d and 3.0.2/3.00c
- Editorial changes

2.8 (^) • Update to EtherCAT IP core release 3.0.10/3.00k

- Clarified DC receive time latching
- ESC DL control register (0x0100[0]): source MAC address bit is set depending
    on the forwarding rule, but not depending on the frame content.
- DC system time difference (0x092C:0x092F) bit [31] description corrected
- Read values of DC start time cyclic operation (0x0990:0x0997), next SYNC
    pulse (0x0998:0x099F are latched when first byte is read
- Corrected PDI register function acknowledge by write for SyncManager
    activation register 0x
- Removed chapter ESC register availability, please refer to application note ESC
    Comparison
- Editorial changes

2.9 (^) • Altera is now Intel

- Editorial changes


##### DOCUMENT HISTORY

II- VI slave controller – register description

```
Version Comment
```
3.0 (^) • Clarified distributed clocks start time cyclic operation (0x0990:0x0997)
extension and auto-activation

- Enhanced PDI error code register 0x030E to 0x030E:0x030F
- Update extended ESC features in user RAM
- Added Avalon and AXI PDI error code 0x030E:0x030F
- Enhanced ESC reset ECAT/PDI 0x0040:0x0041 description
- Editorial changes

3.1 (^) • Add ERR LED codes generated automatically by ESC (0x0139)

- Updated distributed clocks start time cyclic operation (0x0990:0x0997)
    extension and auto-activation
- ECAT event request 0x0200:0x0201 and AL event request 0x0220:0x0223)
    event reset clarified
- DC latch event positive/negative time 0x09B0-0x09BF event reset clarified
- Editorial changes

3.2 (^) • Add PDI1, ESC configuration area B

- Changed naming of SII EEPROM initialized registers to A0-A7/B0-B7 according
    to EEPROM words in both ESC configuration areas
- Added SyncManager deactivation delay (0x0805[2], and 0x0807[7])
- Added SyncManager sequential mode
- Added ESC features supported register bits 0x0008[13:12]
- Added ESC configuration A5, A6 (0x0142:0x0143, 0x0144:0x0145)
- Added DC SyncSignals 1-3 activation (0x0980[3:1])
- Added PHY management interface commands for IEEE802.3 clause 45
    accesses
- Intel is now Altera, Xilinx is now AMD
- Editorial changes

3.3 (^) • Update to EtherCAT IP core V4.0.

- Added ET
- Corrected EEPROM emulation reload data for 32 bit data register
    0x0508[20:16]
- Editorial changes


## CONTENTS

```
slave controller – register description II- VII
```

##### CONTENTS


##### CONTENTS


##### CONTENTS


##### TABLES

slave controller – register description II- XI

- 1 Address space overview CONTENTS
   - 1.1 Scope of section II
   - 1.2 Reserved registers/reserved register bits
   - 1.3 ESC availability tab legend
- 2 Register description
   - 2.1 ESC information
      - 2.1.1 ESC type (0x0000)
      - 2.1.2 ESC revision (0x0001)
      - 2.1.3 ESC build (0x0002:0x0003)
      - 2.1.4 FMMUs supported (0x0004)
      - 2.1.5 SyncManagers supported (0x0005)
      - 2.1.6 RAM size (0x0006)
      - 2.1.7 Port descriptor (0x0007)
      - 2.1.8 ESC features supported (0x0008:0x0009)
   - 2.2 Station address
      - 2.2.1 Station address (0x0010:0x0011)
      - 2.2.2 Station alias (0x0012:0x0013)
   - 2.3 Write protection and reset
      - 2.3.1 Register write enable (0x0020)
      - 2.3.2 Register write protection (0x0021)
      - 2.3.3 ESC write enable (0x0030)
      - 2.3.4 ESC write protection (0x0031)
      - 2.3.5 ESC reset ECAT (0x0040)
      - 2.3.6 ESC reset PDI (0x0041)
   - 2.4 Data link layer
      - 2.4.1 DL control (0x0100:0x0103)
      - 2.4.2 Physical read/write offset (0x0108:0x0109)
      - 2.4.3 DL status (0x0110:0x0111)
   - 2.5 Application layer
      - 2.5.1 AL control (0x0120:0x0121)
      - 2.5.2 AL status (0x0130:0x0131)
      - 2.5.3 AL status code (0x0134:0x0135)
      - 2.5.4 RUN LED override (0x0138)
      - 2.5.5 ERR LED override (0x0139)
   - 2.6 PDI0/ESC configuration area A
      - 2.6.1 PDI0 control (0x0140)
      - 2.6.2 ESC configuration A0 (0x0141)
      - 2.6.3 ESC configuration A5 (0x0142:0x0143)
      - 2.6.4 ESC configuration A6 (0x0144:0x0145)
   - 2.6.5 PDI0 information (0x014E:0x014F) II- VIII slave controller – register description
   - 2.6.6 PDI0 configuration (0x0150:0x0153)
   - 2.6.7 PDI0 user mode from ECAT (0x0158:0x0159)
   - 2.6.8 PDI0 user mode from PDI (0x015C:0x015D)
- 2.7 PDI1/ESC configuration area B
   - 2.7.1 PDI1 control (0x0180)
   - 2.7.2 ESC configuration B0 (0x0181)
   - 2.7.3 ESC configuration B5 (0x0182:0x0183)
   - 2.7.4 ESC configuration B6 (0x0184:0x0185)
   - 2.7.5 ESC configuration B4 (0x0188:0x0189)
   - 2.7.6 PDI1 information (0x018E:0x018F)
   - 2.7.7 PDI1 configuration (0x0190:0x0193)
   - 2.7.8 PDI1 user mode from ECAT (0x0198:0x0199)
   - 2.7.9 PDI1 user mode from PDI (0x019C:0x019D)
- 2.8 Interrupts
   - 2.8.1 ECAT event mask (0x0200:0x0201)
   - 2.8.2 PDI0 AL event mask (0x0204:0x0207)
   - 2.8.3 PDI1 AL event mask (0x020A:0x020D)
   - 2.8.4 ECAT event request (0x0210:0x0211)
   - 2.8.5 AL event request (0x0220:0x0223)
- 2.9 Error counter
   - 2.9.1 RX error counter (0x0300:0x0307)
   - 2.9.2 Forwarded RX error counter (0x0308:0x030B)
   - 2.9.3 ECAT processing unit error counter (0x030C)
   - 2.9.4 PDI0 error counter (0x030D)
   - 2.9.5 PDI0 error code (0x030E:0x030F)
   - 2.9.6 Lost link counter (0x0310:0x0303)
   - 2.9.7 Extended RX error counter (0x0314:0x0317)
   - 2.9.8 RX error code (0x0320:0x0327)
   - 2.9.9 PDI1 error counter (0x0340)
   - 2.9.10 PDI1 error code (0x0341:0x0342)
- 2.10 Watchdog
   - 2.10.1 Watchdog divider (0x0400:0x0401)
   - 2.10.2 Watchdog time PDI0 (0x0410:0x0411)
   - 2.10.3 Watchdog time PDI1 (0x0412:0x0413)
   - 2.10.4 Watchdog time process data (0x0420:0x0421)
   - 2.10.5 Watchdog status process data (0x0440:0x0441)
   - 2.10.6 Watchdog counter process data (0x0442)
   - 2.10.7 Watchdog counter PDI0 (0x0443)
   - 2.10.8 Watchdog counter PDI1 (0x0444)
   - 2.10.9 Watchdog status PDI (0x0448)
- 2.11 SII EEPROM interface slave controller – register description II- IX
   - 2.11.1 EEPROM ECAT access state (0x0500)
   - 2.11.2 EEPROM PDI access state (0x0501)
   - 2.11.3 EEPROM control/status (0x0502:0x0503)
   - 2.11.4 EEPROM address (0x0504:0x0507)
   - 2.11.5 EEPROM data (0x0508:0x050F)
- 2.12 PHY management interface
   - 2.12.1 PHY control/status (0x0510:0x0511)
   - 2.12.2 PHY address (0x0512)
   - 2.12.3 PHY register address (0x0513)
   - 2.12.4 PHY data (0x0514:0x0515)
   - 2.12.5 PHY ECAT access state (0x0516)
   - 2.12.6 PHY PDI access state (0x0517)
   - 2.12.7 PHY port status (0x0518:0x051B)
- 2.13 FMMU
   - 2.13.1 FMMU logical start address (0x0600:0x0603)
   - 2.13.2 FMMU length (0x0604:0x0605)
   - 2.13.3 FMMU logical start bit (0x0606)
   - 2.13.4 FMMU logical stop bit (0x0607)
   - 2.13.5 FMMU physical start address (0x0608:0x0609)
   - 2.13.6 FMMU physical start bit (0x060A)
   - 2.13.7 FMMU type (0x060B)
   - 2.13.8 FMMU activate (0x060C)
   - 2.13.9 FMMU reserved (0x060D:0x060F)
- 2.14 SyncManager
   - 2.14.1 SyncManager start address (0x0800:0x0801)
   - 2.14.2 SyncManager length (0x0802:0x0803)
   - 2.14.3 SyncManager control (0x0804)
   - 2.14.4 SyncManager status (0x0805)
   - 2.14.5 SyncManager activate (0x0806)
   - 2.14.6 SyncManager PDI control (0x0807)
- 2.15 Distributed clocks
   - 2.15.1 Receive times
   - 2.15.2 Time loop control unit
   - 2.15.3 Cyclic unit control
   - 2.15.4 Sync unit
   - 2.15.5 Latch unit
   - 2.15.6 SyncManager event times
- 2.16 ESC-specific registers
   - 2.16.1 Power-on values
   - 2.16.2 ESC health
      - 2.16.3 OTP II- X slave controller – register description
      - 2.16.4 Product and vendor ID
      - 2.16.5 FPGA update
   - 2.17 ESC specific I/O
   - 2.18 User RAM
      - 2.18.1 User RAM (0x0F80:0x0FFF)
      - 2.18.2 ESC features (power-on values of user RAM)
      - 2.18.3 ESC port features (power-on values of user RAM)
   - 2.19 Process data RAM
      - 2.19.1 Process data RAM (0x1000:0xFFFF)
      - 2.19.2 Digital I/O input data PDI0 (0x1000:0x1003)
- 3 Appendix
   - 3.1 Support and service
      - 3.1.1 Beckhoff’s branch offices and representatives
   - 3.2 Beckhoff headquarters
- Table 1: ESC address space TABLES
- Table 2: Decoding port state in ESC DL status register 0x0111 (typical modes only)
- Table 3: ERR LED codes generated automatically by ESC
- Table 4: Digital I/O extended configuration (0x0152:0x0153)
- Table 5: SPI slave extended configuration (0x0152:0x0153)
- Table 6: SPI master extended configuration (0x0152:0x0153)
- Table 7: Asynchronous microcontroller extended configuration (0x0152:0x0153)
- Table 8: Synchronous microcontroller extended configuration (0x0152:0x0153)
- Table 9: Multiplexed asynchronous microcontroller extended configuration (0x0152:0x0153)
- Table 10: EtherCAT bridge extended configuration (0x0152:0x0153)
- Table 11: On-chip bus extended configuration (0x0152:0x0153)
- Table 12: General RX error codes
- Table 13: SII EEPROM interface register overview
- Table 14: EEPROM emulation reload data for 32 bit data register (0x0508:0x050B)
- Table 15: EEPROM emulation reload data for 64 bit data register (0x0508:0x050F)...........................
- Table 16: PHY management interface register overview
- Table 17: FMMU register overview........................................................................................................
- Table 18: SyncManager register overview
- Table 19: OTP Register Overview


##### ABBREVIATIONS

II- XII slave controller – register description

##### ABBREVIATIONS

ADR Address
AL Application Layer
APRW Auto Increment Physical ReadWrite
BHE Bus High Enable
BWR Broadcast Write
DC Distributed Clock
DL Data Link Layer
ECAT EtherCAT
ESC EtherCAT Slave Controller
ESI EtherCAT Slave Information
FCS Frame Check Sequence
FMMU Fieldbus Memory Management Unit
FPRD Configured Address Physical Read
FPRW Configured Address Physical ReadWrite
FPWR Configured Address Physical Write
GPI General Purpose Input
GPO General Purpose Output
IP Intellectual Property
μC Microcontroller
MI (PHY) Management Interface
MII Media Independent Interface
OPB On-chip Peripheral Bus
PDI Process data Interface
RMII Reduced Media Independent Interface
SII Slave Information Interface
SM SyncManager
SoC System on a Chip
SOF Start of Frame
SoPC System on a Programmable Chip
SPI Serial Peripheral Interface
WD Watchdog


## 1 Address space overview CONTENTS

```
slave controller – register description II- 13
```
## 1 Address space overview

An EtherCAT slave controller (ESC) has an address space of 64Kbyte. The first block of 4Kbyte
(0x0000:0x0FFF) is dedicated to registers. The process data RAM starts at address 0x1000, its size
depends on the ESC. The availability of the registers depends on the ESC.

```
Table 1: ESC address space
```
```
Address^1 Length^
(byte)
```
```
Description
```
```
ESC information^
```
0x0000 (^1) Type
0x0001 (^1) Revision
0x0002:0x0003 (^2) Build
0x0004 (^1) FMMUs supported
0x0005 (^1) SyncManagers supported
0x0006 (^1) RAM size
0x0007 (^1) Port descriptor
0x0008:0x0009 (^2) ESC features supported
**Station address**^
0x0010:0x0011 (^2) Configured station address
0x0012:0x0013 (^2) Configured station alias
**Write**^ **protection and reset**^
0x0020 (^1) Register write enable
0x0021 (^1) Register write protection
0x0030 (^1) ESC write enable
0x0031 (^1) ESC write protection
0x0040 (^1) ESC reset ECAT
0x0041 (^1) ESC reset PDI
**Data link layer**^
0x0100:0x0103 (^4) ESC DL control
0x0108:0x0109 (^2) Physical read/write offset
0x0110:0x0111 (^2) ESC DL status
**Application layer**^
0x0120:0x0121 (^2) AL control
0x0130:0x0131 (^2) AL status
0x0134:0x0135 (^2) AL status code
0x0138 (^1) RUN LED override
0x0139 (^1) ERR LED override
**PDI**^0 **/ ESC configuration**^ **A**^
0x0140 (^1) PDI0 control
0x0141 (^1) ESC configuration A
0x0142:0x0143 (^2) ESC configuration A
0x0144:0x0145 (^2) ESC configuration A
0x014E:0x014F (^2) PDI0 information
(^1) Address areas not listed here are reserved. They are not writable. A read access to reserved addresses will
typically return 0.


Address space overview

II- 14 slave controller – register description

```
Address^1 Length^
(byte)
```
```
Description
```
0x0150 (^1) PDI0 configuration
0x0151 (^1) SYNC/LATCH configuration A
0x0152:0x0153 (^2) Extended PDI0 configuration
0x0158:0x0159 (^2) PDI0 user mode from ECAT
0x015C:0x015D (^2) PDI0 user mode from PDI
(^) **PDI1 / ESC configuration B**
0x0180 (^1) PDI1 control
0x0181 (^1) ESC configuration B
0x0182:0x0183 (^2) ESC configuration B
0x0184:0x0185 (^2) ESC configuration B
0x0188:0x0189 (^2) ESC configuration B4 GPIO
0x018E:0x018F (^2) PDI1 information
0x0190 (^1) PDI1 configuration
0x0191 (^1) SYNC/LATCH configuration B
0x0192:0x0193 (^2) Extended PDI1 configuration
0x0198:0x0199 (^2) PDI1 user mode from ECAT
0x019C:0x019D (^2) PDI1 user mode from PDI
(^) **Interrupts**
0x0200:0x0201 (^2) ECAT event mask
0x0204:0x0207 (^4) PDI0 AL event mask
0x020A:0x020D (^4) PDI1 AL event mask
0x0210:0x0211 (^2) ECAT event request
0x0220:0x0223 (^4) AL event request
**Error counters**^
0x0300:0x0307 (^) 4x2 RX error counter[3:0]
0x0308:0x030B (^) 4x1 Forwarded RX error counter[3:0]
0x030C (^1) ECAT Processing Unit error counter
0x030D (^1) PDI0 error counter
0x030E:0x030F 2 PDI0 error code
0x0310:0x0313 (^) 4x1 Lost link counter[3:0]
0x0314:0x0317 (^) 4x1 Extended RX error counter[3:0]
0x0320:0x0327 (^) 4x2 RX error code[3:0]
0x0340 (^1) PDI1 error counter
0x0341 (^1) PDI1 error code
**Watchdogs**^
0x0400:0x0401 (^2) Watchdog divider
0x0410:0x0411 (^2) Watchdog time PDI 0
0x0412:0x0413 (^2) Watchdog time PDI
0x0420:0x0421 (^2) Watchdog time process data
0x0440:0x0441 (^2) Watchdog status process data
0x0442 (^1) Watchdog counter process data
0x0443 (^1) Watchdog counter PDI 0
0x0444 (^1) Watchdog counter PDI
0x0448 (^1) Watchdog status PDI


Address space overview

```
slave controller – register description II- 15
```
```
Address^1 Length^
(byte)
```
```
Description
```
```
SII EEPROM interface^
```
0x0500 (^1) EEPROM configuration
0x0501 (^1) EEPROM PDI access state
0x0502:0x0503 (^2) EEPROM control/status
0x0504:0x0507 (^4) EEPROM address
0x0508:0x050F (^) 4/8 EEPROM data
**PHY**^ **management interface**^
0x0510:0x0511 (^2) PHY management control/status
0x0512 (^1) PHY address
0x0513 (^1) PHY register address
0x0514:0x0515 (^2) PHY data
0x0516 (^1) PHY management ECAT access state
0x0517 (^1) PHY management PDI access state
0x0518:0x051B (^4) PHY port status
**0x0600:0x06FF 16x16 FMMU[15:0]**
+0x0:0x3 (^4) Logical start address
+0x4:0x5 (^2) Length
+0x6 (^1) Logical start bit
+0x7 (^1) Logical stop bit
+0x8:0x9 (^2) Physical start address
+0xA (^1) Physical start bit
+0xB (^1) Type
+0xC (^1) Activate
+0xD:0xF (^3) Reserved
**0x0800:0x087F 16x8 SyncManager[15:0]**
+0x0:0x1 (^2) Physical start address
+0x2:0x3 (^2) Length
+0x4 (^1) Control register
+0x5 (^1) Status register
+0x6 (^1) Activate
+0x7 (^1) PDI control
**0x0900:0x09FF Distributed clocks (DC)
DC –**^ **receive times**^
0x0900:0x0903 (^4) Receive time port 0
0x0904:0x0907 (^4) Receive time port 1
0x0908:0x090B (^4) Receive time port 2
0x090C:0x090F (^4) Receive time port 3
**DC –**^ **time**^ **loop control**^ **unit**^
0x0910:0x0917 (^) 4/8 System time
0x0918:0x091F (^) 4/8 Receive time ECAT processing unit
0x0920:0x0927 (^) 4/8 System time offset
0x0928:0x092B (^4) System time delay
0x092C:0x092F (^4) System time difference
0x0930:0x0931 (^2) Speed counter start
0x0932:0x0933 (^2) Speed counter diff
0x0934 (^1) System time difference filter depth


Address space overview

II- 16 slave controller – register description

```
Address^1 Length^
(byte)
```
```
Description
```
0x0935 (^1) Speed counter filter depth
0x0936 (^1) Receive time latch mode
0x0938:0x0939 (^2) Speed counter diff direct control
**DC –**^ **cyclic unit control**^
0x0940:0x0943 (^4) SYNC2 cycle time
0x0944:0x0947 (^4) SYNC3 cycle time
0x0950:0x0957 (^) 4/8 Next SYNC2 pulse
0x0958:0x095F (^) 4/8 Next SYNC3 pulse
0x0980 (^1) Cyclic unit control
**DC –**^ **sync**^ **unit**^
0x0981 (^1) Activation
0x0982:0x0983 (^2) Pulse length of SyncSignals
0x0984 (^1) Activation status
0x0986 (^1) Activation SYNC2/
0x098C (^1) SYNC2 status
0x098D (^1) SYNC3 status
0x098E (^1) SYNC0 status
0x098F (^1) SYNC1 status
0x0990:0x0997 (^) 4/8 Start time cyclic operation/next SYNC0 pulse
0x0998:0x099F (^) 4/8 Next SYNC1 pulse
0x09A0:0x09A3 (^4) SYNC0 cycle time
0x09A4:0x09A7 (^4) SYNC1 cycle time
**DC –**^ **latch unit**^
0x09A8 (^1) LATCH0 control
0x09A9 (^1) LATCH1 control
0x09AA (^1) LATCH2 control
0x09AB (^1) LATCH3 control
0x09AC (^1) LATCH2 status
0x09AD (^1) LATCH3 status
0x09AE (^1) LATCH0 status
0x09AF (^1) LATCH1 status
0x09B0:0x09B7 (^) 4/8 LATCH0 time positive edge
0x09B8:0x09BF (^) 4/8 LATCH0 time negative edge
0x09C0:0x09C7 (^) 4/8 LATCH1 time positive edge
0x09C8:0x09CF (^) 4/8 LATCH1 time negative edge
0x09D0:0x09D7 (^) 4/8 LATCH2 time positive edge
0x09D8:0x09DF (^) 4/8 LATCH2 time negative edge
0x09E0:0x09E7 (^) 4/8 LATCH3 time positive edge
0x09E8:0x09EF (^) 4/8 LATCH3 time negative edge
**DC –**^ **SyncManager event**^ **times**^
0x09F0:0x09F3 (^4) EtherCAT buffer change event time
0x09F8:0x09FB (^4) PDI Buffer start event time
0x09FC:0x09FF (^4) PDI Buffer change event time


Address space overview

```
slave controller – register description II- 17
```
```
Address^1 Length^
(byte)
```
```
Description
```
```
ESC-specific^
```
0x0E00:0x0EFF (^256) ESC-specific registers:

- EtherCAT ASICs (power-on values)
- IP core (Product and vendor ID)
- ESC20 (FPGA update)
**ESC-specific I/O**^

0x0F00:0x0F03 (^4) Digital I/O output data
0x0F08:0x0F0B (^4) Digital I/O input data
0x0F10:0x0F17 (^1) - 8 General purpose outputs
0x0F18:0x0F1F (^1) - 8 General purpose inputs
**User RAM**^
0x0F80:0x0FFF (^128) User RAM
**Process data**^ **RAM**^
0x1000:0x1003 (^4) Digital I/O input data
0x1000:0x13FF
0x1000:0x17FF
0x1000:0x1FFF
0x1000:0x2FFF
0x1000:0x4FFF
0x1000:0x8FFF
0x1000:0xFFFF

##### 1 KB

##### 2 KB

##### 4 KB

##### 8 KB

##### 16 KB

##### 32 KB

##### 60 KB

```
Process data RAM
```
For registers longer than one byte, the LSB has the lowest and MSB the highest address.


Address space overview

II- 18 slave controller – register description

### 1.1 Scope of section II

Section II contains detailed information about all ESC registers. This section is also common to all
Beckhoff ESCs, thus registers, register bits, or features are described which might not be available in
a specific ESC. Refer to the register overview in section III of a specific ESC to find out which registers
are available. Additionally, refer to the feature details overview in section III of a specific ESC to find
out which features are available.

The following Beckhoff ESCs are covered by section II:

- ET1200- 0003
- ET1100- 0003
- ET1150- 0002
- EtherCAT IP core for FPGAs (V4.0)
- ESC20 (Build 22)

### 1.2 Reserved registers/reserved register bits

Reserved registers must not be written, reserved register bits have to be written as 0. Read values of
reserved registers or register bits have to be ignored. Reserved registers or register bits initialized by
EEPROM values have to be initialized with 0.

Reserved EEPROM words of the ESC configuration area have to be 0.


Address space overview

```
slave controller – register description II- 19
```
### 1.3 ESC availability tab legend

The availability of registers and exceptions for individual register bits or IP core versions are indicated
in a small area at the top right edge of each register table.

**Example 1:**

```
ESC20 ET1100 ET1200 IP core
[5] V2.0.0/
V2.00a
```
- Register is not available for ESC20 (reserved)
- Register is available for ET1100 (all bits mentioned below)
- Register is available for ET1200, except for bit 5 which is reserved
- Register is available for IP core since V2.0.0/V2.00a, reserved for previous versions

**Example 2:**

```
ESC20 ET1100 ET1200 IP core
Optional
writable
```
```
[5]
V2.0.0/
V2.00a
[15:8]
V4.0.
```
- Register is available for ET1100 (read), write access is optionally available (e.g. ESI EEPROM or
    IP core configuration)
- Register is available for IP core
- Functionality of bit [5] is available since V2.0.0/V2.00a, bit 5 is not available and reserved for
    previous versions
- Functionality of bits [15:8] is available since V4.0.0, bits [15:8] are not available and reserved for
    previous versions

**Example 3:**

```
ESC20 ET1100 ET1200 IP core
[63:16]
optional
```
```
V2.0.0/
V2.00a
```
- Register is available for ET1100, bits [63:16] are optionally available (e.g. ESI EEPROM or IP core
    configuration)
- Register is optionally available/configurable for IP core since V2.0.0/V2.00a (“IP core” is not **bold** )


II- 20 slave controller – register description

## 2 Register description

### 2.1 ESC information

#### 2.1.1 ESC type (0x0000)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
7:0 Type of EtherCAT controller
```
```
Beckhoff ESCs
First terminals 0x
ESC10, ESC20 0x
First EK1100 0x
Customer FPGA IP core 0x
Internal FPGA IP core 0x
ET1100, ET1150 0x
ET120x 0x
```
```
r/- r/-^ ESC dep.^
```

```
slave controller – register description II- 21
```
#### 2.1.2 ESC revision (0x0001)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
7:0 Revision of EtherCAT controller
```
```
Beckhoff ESCs
ET1100 0x00
ET1150 0x50
ET1200 0x00
FPGA IP core: major version X (version X.Y.Z)
Other 0x00
```
```
r/- r/-^ ESC dep.^
```
#### 2.1.3 ESC build (0x0002:0x0003)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
15:0 Build of EtherCAT controller
```
```
Beckhoff ESCs
FPGA IP core (version X.Y.Z):
[3:0] maintenance version Z
[7:4] minor version Y
[15:8] patch level / development build:
0x00 original release
0x01-0x0F patch level of original release
0x10-0xFF development build
```
```
r/- r/-^ ESC dep.^
```
#### 2.1.4 FMMUs supported (0x0004)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
7:0 Number of supported FMMU channels (or
entities)
```
```
r/- r/- ESC20: 4
IP core: depends on
configuration
ET1100: 8
ET1150: 16
ET120 0 : 3
```
#### 2.1.5 SyncManagers supported (0x0005)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
7:0 Number of supported SyncManager channels
(or entities)
```
```
r/- r/- ESC20: 4^
IP core: depends on
configuration
ET1100: 8
ET1150: 16
ET120 0 : 4
```

II- 22 slave controller – register description

#### 2.1.6 RAM size (0x0006)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
7:0 Process data RAM size supported in Kbyte
ECAT read:
Total process data RAM size minus
PDI private RAM size
PDI read:
Total process data RAM size
```
```
r/- r/- ESC20: 4^
IP core 0-60, depends on
configuration
ET1100: 8
ET1150: 16
ET1200: 1
```
#### 2.1.7 Port descriptor (0x0007)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
(^) Port configuration:
00: Not implemented
01: Not configured (SII EEPROM)
10: EBUS
11: Ethernet (MII/RMII/RGMII)
1:0 (^) Port 0 r/- r/- ESC and ESC
configuration dep.
3:2 (^) Port 1 r/- r/-
5:4 (^) Port 2 r/- r/-
7:6 (^) Port 3 r/- r/-

#### 2.1.8 ESC features supported (0x0008:0x0009)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
(^0) FMMU operation:
0: Bit-oriented
1: Byte-oriented
r/- r/- 0
(^1) Unused register access:
0: allowed
1: not supported
r/- r/-^0
(^2) Distributed clocks:
0: Not available
1: Available
r/- r/-^ ET110^0 : 1^
ET1150: 1
ET1200: 1
ESC20: 1
IP core: depends on
configuration
(^3) Distributed clocks (width):
0: 32 bit
1: 64 bit
r/- r/-^ ET1100: 1^
ET1150: 1
ET1200: 1
IP core: depends on
configuration
Others : 0
(^4) Low jitter EBUS:
0: Not available, standard jitter
1: Available, jitter minimized
r/- r/-^ ET1100: 1^
ET1150: 1
ET1200: 1
Others : 0
(^5) Enhanced link detection EBUS:
0: Not available
1: Available
r/- r/-^ ET1100: 1^
ET1200: 1
Others : 0
(^6) Enhanced link detection MII:
0: Not available
1: Available
r/- r/-^ ET1100: 1^
ET1150: 1
ET1200: 1
Others : 0


```
slave controller – register description II- 23
```
```
Bit Description ECAT^ PDI^ Reset value^
```
(^7) Separate handling of FCS errors:
0: Not supported
1: Supported, frames with wrong FCS and
additional nibble will be counted
separately in Forwarded RX error
counter
r/- r/-^ ET1100: 1^
ET1150: 1
ET1200: 1
IP core: 1
Others : 0
(^8) Enhanced DC SYNC activation:
0: Not available
1: Available
NOTE: This feature refers to registers 0x981[7:3]
and 0x0984
r/- r/-^ IP core:
depends on version
Others : 0
(^9) EtherCAT LRW command support:
0: Supported
1: Not supported
r/- r/-^0
(^10) EtherCAT read/write command support
(BRW, APRW, FPRW):
0: Supported
1: Not supported
r/- r/-^0
(^11) Fixed FMMU/SyncManager configuration:
0: Variable configuration
1: Fixed configuration (refer to
documentation of supporting ESCs)
r/- r/-^0
(^12) SyncManager sequential mode:
0: Not supported
1: Supported
r/- r/-^ ET1150: 1^
IP core:
since V4.0.0
Others : 0
15:1 (^3) Reserved r/- r/- 0


II- 24 slave controller – register description

### 2.2 Station address

#### 2.2.1 Station address (0x0010:0x0011)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
15:0 (^) Address used for node addressing
(FPRD/FPWR/FPRW/FRMW commands).
r/w r/-^0

#### 2.2.2 Station alias (0x0012:0x0013)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
15:0 (^) Alias address used for node addressing
(FPRD/FPWR/FPRW/FRMW commands).
The use of this alias is activated by register
DL control bit 0x0100[ 24 ].
NOTE: EEPROM value is only transferred into this
register at first EEPROM load after power-on or
reset.
ESC20 exception: EEPROM value is transferred
into this register after each EEPROM reload
command.
r/- r/w^0 until first EEPROM
load, then EEPROM
word A4


```
slave controller – register description II- 25
```
### 2.3 Write protection and reset

#### 2.3.1 Register write enable (0x0020)

```
ESC20 ET1100 ET1150 ET1200 IP core
read Readable
since
V2.4.0/
V2.04a
Bit Description ECAT^ PDI^ Reset value^
0 If register write protection is enabled, this
register has to be written in the same
Ethernet frame (value does not matter)
before other writes to this station are allowed.
This bit is self-clearing at the beginning of the
next frame (SOF), or if register write
protection is disabled.
```
```
r/w r/- 0
```
7:1 (^) Reserved, write 0 r/- r/- 0

#### 2.3.2 Register write protection (0x0021)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Register write protection:
0: Protection disabled
1: Protection enabled
Registers 0x0000:0x0F7F are write-protected,
except for 0x0020 and 0x0030.
r/w r/-^0
7:1 (^) Reserved, write 0 r/- r/- 0


II- 26 slave controller – register description

#### 2.3.3 ESC write enable (0x0030)

```
ESC20 ET1100 ET1150 ET1200 IP core
read Readable
since
V2.4.0/
V2.04a
Bit Description ECAT^ PDI^ Reset value^
0 If ESC write protection is enabled, this
register has to be written in the same
Ethernet frame (value does not matter)
before other writes to this station are allowed.
This bit is self-clearing at the beginning of the
next frame (SOF), or if ESC write protection
is disabled.
```
```
r/w r/- 0
```
```
7:1 Reserved, write 0 r/- r/- 0
```
#### 2.3.4 ESC write protection (0x0031)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Write protect:
0: Protection disabled
1: Protection enabled
All areas are write-protected, except for 0x0030.
r/w r/-^0
7:1 (^) Reserved, write 0 r/- r/- 0


```
slave controller – register description II- 27
```
#### 2.3.5 ESC reset ECAT (0x0040)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
Write
7:0 A reset is asserted after writing the reset
sequence 0x52 (‘R’), 0x45 (‘E’) and 0x53 (‘S’)
in this register with 3 consecutive frames.
Any other frame which does not continue the
sequence by writing the next expected value
will cancel the reset procedure.
```
```
NOTE: Some ESCs require to repeat this
sequence until the ESC is actually reset. Do not
use VLAN tagged frames.
```
```
r/w r/-^0
```
```
Read
1:0 Progress of the reset procedure:
00: initial/reset state
01: after writing 0x52 (‘R’), when previous
state was 00
10: after writing 0x45 (‘E’), when previous
state was 01
11: after writing 0x53 (‘S’), when previous
state was 10.
This value must not be observed
because the ESC enters reset when this
state is reached, resulting in state 00.
```
```
r/w r/-^00
```
```
7:2 Reserved, write 0 r/- r/- 0
```
#### 2.3.6 ESC reset PDI (0x0041)

```
ESC20 ET1100 ET1150 ET1200 IP core
Since
V2.2.0/
V2.02a
Bit Description ECAT^ PDI^ Reset value^
Write
7:0 A reset is asserted after writing the reset
sequence 0x52 (‘R’), 0x45 (‘E’) and 0x53 (‘S’)
in this register with 3 consecutive commands.
Any other command which does not continue
the sequence by writing the next expected
value will cancel the reset procedure.
```
```
r/- r/w 0
```
```
Read
1:0 Progress of the reset procedure:
00: initial/reset state
01: after writing 0x52 (‘R’), when previous
state was 00
10: after writing 0x45 (‘E’), when previous
state was 01
11: after writing 0x53 (‘S’), when previous
state was 10.
This value must not be observed
because the ESC enters reset when this
state is reached, resulting in state 00.
```
```
r/- r/w^00
```
```
7:2 Reserved, write 0 r/- r/- 0
```

II- 28 slave controller – register description

### 2.4 Data link layer

#### 2.4.1 DL control (0x0100:0x0103)

```
ESC20 ET1100 ET1150 ET1200 IP core
[ 7 :1]
[23:19]
```
```
[7:2]
[23:20]
-0003
```
```
[7:2]
[23:20]
-0003
```
```
[19]
[24]
opt. before
V2.4.0/
V2.04a
[23:20]
V2.4.3/
V2.04d
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Forwarding rule:
0: Forward non-EtherCAT frames:
EtherCAT frames are processed, non-
EtherCAT frames are forwarded without
processing or modification. The source
MAC address is not changed for any
frame.
1: Destroy non-EtherCAT frames:
EtherCAT frames are processed, non-
EtherCAT frames are destroyed. The
source MAC address is changed by the
processing unit for every frame
(SOURCE_MAC[1] is set to 1 – locally
administered address).
NOTE: EEPROM value is only taken over at first
EEPROM load after power-on or reset
r/w r/-^ ET1150, IP core^ since
V4.0.0:
1, later EEPROM word
A6[1] inverted
Others: 1
(^1) Temporary use of settings in
0x0100:0x0103[8:15]:
0: permanent use
1: use for about 1 second, then revert to
previous settings
r/w r/-^0
7:2 (^) Reserved, write 0 r/- r/- 0
9:8 (^) Loop port 0:
00: Auto
01: Auto close
10: Open
11: Closed
NOTE:
Loop open means sending/receiving over this port
is enabled, loop closed means sending/receiving
is disabled and frames are forwarded to the next
open port internally.
Auto: loop closed at link down, opened at link up
Auto close: loop closed at link down, opened with
writing 01 again after link up (or receiving a valid
Ethernet frame at the closed port)
Open: loop open regardless of link state
Closed: loop closed regardless of link state
r/w* r/-^00
11:10 (^) Loop port 1:
00: Auto
01: Auto close
10: Open
11: Closed
r/w* r/-^00


```
slave controller – register description II- 29
```
```
Bit Description ECAT^ PDI^ Reset value^
```
13:12 (^) Loop port 2:
00: Auto
01: Auto close
10: Open
11: Closed
r/w* r/-^00
15:14 (^) Loop port 3:
00: Auto
01: Auto close
10: Open
11: Closed
r/w* r/-^ ET1200: 11^
others: 00
18:16 (^) RX FIFO size (ESC delays start of forwarding
until FIFO is at least half full).
RX FIFO size/RX delay reduction** :
Value: EBUS: MII:
0: -50 ns -40 ns (-80 ns***)
1: -40 ns -40 ns (-80 ns***)
2: -30 ns -40 ns
3: -20 ns -40 ns
4: -10 ns no change
5: no change no change
6: no change no change
7: default default
NOTE: EEPROM value is only taken over at first
EEPROM load after power-on or reset
r/w r/-^ ET1150,^ IP core^ since
V2.4.3/V2.04d:
7, later EEPROM word
A5[11:9] inverted
Others: 7
(^19) EBUS low jitter:
0: Normal jitter
1: Reduced jitter
r/w r/-^0
21:20 (^) Reserved, write 0 r/w r/- 0, later EEPROM word
A5[5:4]
(^22) EBUS remote link down signaling time:
0: Default (~660 ms)
1: Reduced (~80 μs)
r/w r/-^ 0, later EEPROM word
A5[6]
(^23) Reserved, write 0 r/w r/- 0, later EEPROM word
A5[7]


II- 30 slave controller – register description

```
Bit Description ECAT^ PDI^ Reset value^
```
(^24) Station alias:
0: Ignore station alias
1: Alias can be used for all configured
address command types (FPRD,
FPWR, ...)
r/w r/-^0
31:25 (^) Reserved, write 0 r/- r/- 0
* Loop configuration changes are delayed until the end of a currently received or transmitted frame at the port.
** The possibility of RX FIFO size reduction depends on the clock source accuracy of the ESC and of every
connected EtherCAT/Ethernet devices (master, slave, etc.). RX FIFO size of 7 is sufficient for 100ppm accuracy,
FIFO size 0 is possible with 25ppm accuracy (frame size of 1518/1522 byte).
*** Reduction by 80 ns for ET1150, IP core since V3.0.0/V3.00c only, otherwise reduction by 40 ns.


```
slave controller – register description II- 31
```
#### 2.4.2 Physical read/write offset (0x0108:0x0109)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
15:0 This register is used for ReadWrite
commands in device addressing mode
(FPRW, APRW, BRW).
The internal read address is directly taken
from the offset address field of the EtherCAT
datagram header, while the internal write
address is calculated by adding the physical
read/write offset value to the offset address
field.
Internal read address = ADR,
internal write address = ADR + R/W-offset
```
```
r/w r/- 0
```

II- 32 slave controller – register description

#### 2.4.3 DL status (0x0110:0x0111)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
(^0) PDI operational/EEPROM loaded correctly:
0: EEPROM not loaded, PDI not
operational (no access to process data
RAM)
1: EEPROM loaded correctly, PDI
operational (access to process data
RAM)
r*/- r/-^0
(^1) PDI watchdog status (combined):
0: Watchdog expired
1: Watchdog reloaded
r*/- r/-^0
(^2) Enhanced link detection:
0: Deactivated for all ports
1: Activated for at least one port
NOTE: EEPROM value is only transferred into this
register at first EEPROM load after power-on or
reset
r*/- r/-^ ET110^0 /ET1150/^
ET1200:
1 until first EEPROM
load, then EEPROM
word A0[9]
IP core with feature:
1 until first EEPROM
load, then 0 if EEPROM
word A0[9]=0 and
EEPROM word
A0[15:12]=0x0, else 1
Others: 0
(^3) Reserved r*/- r/- 0
(^4) Physical link on port 0:
0: No link
1: Link detected
r*/- r/-^0
(^5) Physical link on port 1:
0: No link
1: Link detected
r*/- r/-^0
(^6) Physical link on port 2:
0: No link
1: Link detected
r*/- r/-^0
(^7) Physical link on port 3:
0: No link
1: Link detected
r*/- r/-^0
(^8) Loop port 0:
0: Open
1: Closed
r*/- r/-^0
(^9) Communication on port 0:
0: No stable communication
1: Communication established
r*/- r/-^0
(^10) Loop port 1:
0: Open
1: Closed
r*/- r/-^0
(^11) Communication on port 1:
0: No stable communication
1: Communication established
r*/- r/-^0


```
slave controller – register description II- 33
```
```
Bit Description ECAT^ PDI^ Reset value^
```
(^12) Loop port 2:
0: Open
1: Closed
r*/- r/-^0
(^13) Communication on port 2:
0: No stable communication
1: Communication established
r*/- r/-^0
(^14) Loop port 3:
0: Open
1: Closed
r*/- r/-^ ET120^0 : 00 until
EEPROM loaded, then
11 if EtherCAT bridge
(port 3) selected and
0x0150[1]=1
Others: 00
(^15) Communication on port 3:
0: No stable communication
1: Communication established
r*/- r/-^
* Reading DL status register (any byte) from ECAT clears ECAT event request 0x0210[2]. Avoid reading DL
status register from PDI.

## Table 2: Decoding port state in ESC DL status register 0x0111 (typical modes only)

```
Register
0x0111
```
```
Port 3 Port 2^ Port 1^ Port 0^
```
0x55 No link, closed No link, closed No link, closed (^) No link, closed
0x56 No link, closed No link, closed No link, closed (^) Link, open
0x5 9 No link, closed No link, closed Link, open (^) No link, closed
0x5A No link, closed No link, closed Link, open (^) Link, open
0x6 5 No link, closed Link, open No link, closed (^) No link, closed
0x6 6 No link, closed Link, open No link, closed (^) Link, open
0x6 9 No link, closed Link, open Link, open (^) No link, closed
0x6A No link, closed Link, open Link, open (^) Link, open
0x 95 Link, open No link, closed No link, closed (^) No link, closed
0x 96 Link, open No link, closed No link, closed (^) Link, open
0x 99 Link, open No link, closed Link, open (^) No link, closed
0x9A Link, open No link, closed Link, open (^) Link, open
0xA5 Link, open Link, open No link, closed (^) No link, closed
0xA6 Link, open Link, open No link, closed (^) Link, open
0xA9 Link, open Link, open Link, open (^) No link, closed
0xAA Link, open Link, open Link, open (^) Link, open
0xD5 Link, closed No link, closed No link, closed (^) No link, closed
0xD6 Link, closed No link, closed No link, closed (^) Link, open
0xD9 Link, closed No link, closed Link, open (^) No link, closed
0xDA Link, closed No link, closed Link, open (^) Link, open


II- 34 slave controller – register description

### 2.5 Application layer

#### 2.5.1 AL control (0x0120:0x0121)

```
ESC20 ET1100 ET1150 ET1200 IP core
[15:5]
(w ack)
(w ack)
(w ack)
```
```
[15:5]
V2.4.0/
V2.04a
Bit Description ECAT^ PDI^ Reset value^
```
3:0 (^) Initiate state transition of the application
device state machine:
1: Request init state
3: Request bootstrap state
2: Request pre-operational state
4: Request safe-operational state
8: Request operational state
r/(w) r/^
(w ack)*
1
(^4) Error indication acknowledge:
0: No acknowledge of error indication in
AL status register
1: Acknowledge of error indication in AL
status register
r/(w) r/^
(w ack)*
0
(^5) Device identification:
0: No request
1: Device identification request
r/(w) r/^
(w ack)*
0
(^6) Warning indication acknowledge:
0: No acknowledge of warning indication in
AL status register
1: Acknowledge of warning indication in AL
status register
r/(w) r/^
(w ack)*
0
15: (^7) Reserved, write 0 r/(w) r/
(w ack)*
0
NOTE: AL control register behaves like a mailbox if device emulation is off (0x0141[0]=0): The PDI has to
read/write* the AL control register after ECAT has written it. Otherwise ECAT cannot write again to the AL control
register. After reset, AL control register can be written by ECAT. (Regarding mailbox functionality, both low and
high byte of the AL control register trigger read/write functions, e.g., reading 0x0121 is sufficient to make this
register writable again)
If device emulation is on, the AL control register can always be written, its content is copied to the AL status
register.
* PDI register function acknowledge by write command is disabled: reading AL control from PDI (any byte) clears
AL event request 0x0220[0]. Writing to this register from PDI is not possible. Default if feature is not available.
PDI register function acknowledge by write command is enabled: writing AL control from PDI (any byte) clears
AL event request 0x0220[0]. Writing to this register from PDI is possible; write value is ignored (write 0).


```
slave controller – register description II- 35
```
#### 2.5.2 AL status (0x0130:0x0131)

```
ESC20 ET1100 ET1150 ET1200 IP core
[15:5] [15:5]
V2.4.0/
V2.04a
Bit Description ECAT^ PDI^ Reset value^
```
3:0 (^) Actual state of the application device state
machine:
1: Init state
3: Bootstrap state
2: Pre-operational state
4: Safe-operational state
8: Operational state
r*/- r/(w)^1
(^4) Error indication:
0: Device is in state as requested or flag
cleared by command
1: Device has not entered requested state
or changed state as result of a local
action
r*/- r/(w)^0
(^5) Device identification:
0: Device identification not valid
1: Device identification loaded
r*/- r/(w)^0
(^6) Warning indication:
0: No warning
1: Warning indication in AL status code
register 0x0134:0x0135)
r*/- r/(w)^0
15:7 (^) Reserved, write 0 r*/- r/(w) 0
NOTE: AL status register is only writable from PDI if device emulation is off (0x0141[0]=0), otherwise AL status
register will reflect AL control register values. Avoid reading AL status register from PDI.
* Reading AL status (any byte) from ECAT clears ECAT event request 0x0210[3].

#### 2.5.3 AL status code (0x0134:0x0135)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
15:0 AL status code r/- r/w 0
```

II- 36 slave controller – register description

#### 2.5.4 RUN LED override (0x0138)

```
ESC20 ET1100 ET1150 ET1200 IP core
V2.3.0/
V2.03a
Bit Description ECAT^ PDI^ Reset value^
```
3:0 (^) LED code:
0x0: Off
0x1: Flash 1x
0x2-0xC: Flash 2x – 12x
0xD: Blinking
0xE: Flickering
0xF: On
AL status:
Init (1)
SafeOp (4)

-
PreOp (2)
Bootstrap (3)
Operational (8)

```
r/w r/w^0
```
```
4 Enable override:
0: Override disabled
1: Override enabled
```
```
r/w r/w^0
```
```
7:5 Reserved, write 0 r/w r/w 0
```
NOTE: Changes to AL status register (0x0130) with valid values will disable RUN LED override (0x0138[4]=0).
The value read in this register always reflects current LED output.

#### 2.5.5 ERR LED override (0x0139)

```
ESC20 ET1100 ET1150 ET1200 IP core
V2.3.0/
V2.03a
Bit Description ECAT^ PDI^ Reset value^
3:0 LED code:
0x0: Off
0x1-0xC: Flash 1x – 12x
0xD: Blinking
0xE: Flickering
0xF: On
```
```
r/w r/w^0
```
```
4 Enable override:
0: Override disabled
1: Override enabled
```
```
r/w r/w^0
```
```
7:5 Reserved, write 0 r/w r/w 0
```
NOTE: Automatically generated conditions will disable ERR LED override (0x0139[4]=0). The value read in this
register always reflects current LED output.


```
slave controller – register description II- 37
```
## Table 3: ERR LED codes generated automatically by ESC

```
ESC20 ET1100 ET1150 ET1200 IP core
V2.3.0/
V2.03a
```
**Code LED Description**^

0x1 (^) Flash 1x Local error

- AL status register error indication 0x0130[4] is set
- requires device emulation off (0x0141[0]=0)
NOTE: ET1150, IP core since V3.0.0/V3.00c
CAUTION: If the μController makes a state change with error indication bit 0x0130[4]
set after a process data watchdog timeout, it has to manually set the ERR LED to
double flash again (otherwise the ESC would generate a single flash due to the active
error indication bit automatically).

0x2 Flash 2x (^) Process data watchdog expired

- requires AL status = operational state (0x0130[3:0]=8)

0xD Blinking (^) General configuration error

- PDI configuration not supported
- Invalid hardware configuration (ET1150)

0xE Flickering (^) Booting error

- SII EEPROM loading error

0xF On (^) Critical communication or application controller error

- PDI watchdog expired (only PDIs which are connected to a μController)
- ESC license error/timebomb expired (IP core)
- ESC build-in self-test (BIST) error (ET1150)


II- 38 slave controller – register description

### 2.6 PDI0/ESC configuration area A

#### 2.6.1 PDI0 control (0x0140)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
7:0 (^) Process data interface:
0x00: Interface deactivated (no PDI)
0x01: 4 digital input
0x02: 4 digital output
0x03: 2 digital input and 2 digital output
0x04: Digital I/O
0x05: SPI slave
0x06: Oversampling I/O
0x07: EtherCAT bridge (port 3)
0x08: 16/64 bit asynchronous
microcontroller interface
0x09: 8/32 bit asynchronous
microcontroller interface
0x0A: 16/64 bit synchronous
microcontroller interface
0x0B: 8/32 bit synchronous microcontroller
interface
0x0C: 16/64 bit multiplexed asynchronous
microcontroller interface
0x0D: 8/32 bit multiplexed asynchronous
microcontroller interface
0x0E: 16/64 bit multiplexed synchronous
microcontroller interface
0x0F: 8/32 bit multiplexed synchronous
microcontroller interface
0x10: 32 digital input and 0 digital output
0x11: 24 digital input and 8 digital output
0x12: 16 digital input and 16 digital output
0x13: 8 digital input and 24 digital output
0x14: 0 digital input and 32 digital output
0x15: SPI master
0x80: On-chip bus
Others: Reserved
r/- r/-^ IP core: depends^ on
configuration
Others: 0, later
EEPROM word A0[7:0]


```
slave controller – register description II- 39
```
#### 2.6.2 ESC configuration A0 (0x0141)

```
ESC20 ET1100 ET1150 ET1200 IP core
[7:1] [7:4] [7:2] [7:4]
V2.2.0/
V2.02a
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Device emulation (control of AL status):
0: AL status register has to be set by PDI
1: AL status register will be set to value
written to AL control register
r/- r/-^ IP core: 1 with digital^ I/O
PDI, PDI_EMULATION
pin with μC/on-chip bus
Others: 0, later
EEPROM word A 0 [8]
(^1) Enhanced link detection all ports:
0: disabled (if bits [7:4]=0)
1: enabled at all ports (overrides bits [7:4])
r/- r/-^1 , later EEPROM word
A0[9]
(^2) Distributed clocks SYNC unit:
0: disabled (power saving)
1: enabled
r/- r/-^ IP core: depends^ on
configuration
Others: 0, later
EEPROM word
(^3) Distributed clocks latch unit: A0[11:10]^
0: disabled (power saving)
1: enabled
r/- r/-^
(^4) Enhanced link port 0:
0: disabled (if bit 1=0)
1: enabled
r/- r/-^1 , later EEPROM word
A0[15:12]
(^5) Enhanced link port 1:
0: disabled (if bit 1=0)
1: enabled
r/- r/-^
(^6) Enhanced link port 2:
0: disabled (if bit 1=0)
1: enabled
r/- r/-^
(^7) Enhanced link port 3:
0: disabled (if bit 1=0)
1: enabled
r/- r/-^
NOTE: EEPROM values of bits 1, 4, 5, 6, and 7 are only transferred into this register at first EEPROM load after
power-on or reset.


II- 40 slave controller – register description

#### 2.6.3 ESC configuration A5 (0x0142:0x0143)

**2.6.3.1 ESC configuration A5 ET11xx (0x0142:0x0143)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[6]
Bit Description ECAT^ PDI^ Reset value^
0 Reserved, set EEPROM value to 0 r/- r/-^ 0, later EEPROM word
A5
```
(^1) Disable port 1:
0: port 1 enabled
1: port 1 disabled (power saving)
r/- r/-^
(^2) System time control:
0: System time ECAT-controlled
1: System time PDI-controlled
r/- r/-^
(^3) SyncManager deactivation delay initialization
state:
0: Disabled
1: Enabled
r/- r/-^
5:4 (^) Reserved, set EEPROM value to 0 r/- r/-
(^6) EBUS remote link down signaling time
default value for 0x0100[22]:
0: Default (~660 ms)
1: Reduced (~80 μs)
r/- r/-^
8: (^7) Reserved, set EEPROM value to 0 r/- r/-


```
slave controller – register description II- 41
```
```
Bit Description ECAT^ PDI^ Reset value^
```
(^8) Distributed clocks time loop control unit:
0: Disabled
1: Enabled
NOTE: TIME loop control unit is always enabled if
SyncSignals/latchSignals are enabled in
0x0141[3:2]
r/- r/-^
11:9 (^) FIFO size reduction (loaded into register
0x0100[18:16]):
000: FIFO size 7
001: FIFO size 6
010: FIFO size 5
011: FIFO size 4
100: FIFO size 3
101: FIFO size 2
110: FIFO size 1
111: FIFO size 0
r/- r/-^
15:12 (^) Reserved, set EEPROM value to 0 r/- r/-
NOTE: EEPROM values of bits 6, 9, 10, and 11 are only transferred into this register at first EEPROM load after
power-on or reset.


### 2.6.5 PDI0 information (0x014E:0x014F) II- VIII slave controller – register description

#### 2.6.4 ESC configuration A6 (0x0144:0x0145)

**2.6.4.1 ESC configuration A6 (0x0144)**

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
0 ESC configuration area B present:
0: Not available
1: Available
```
```
r/- r/-^ 0, later EEPROM word
A6[7:0]
```
```
1 Default value for 0x0100[0]:
0: Default value for 0x0100[0]=1
1: Default value for 0x0100[0]=0
```
```
r/- r/-^
```
7.2 (^) Reserved, set EEPROM value to 0 r/- r/-
**2.6.5 PDI0 information (0x014E:0x014F)**
ESC20 ET1100 **ET1150** ET1200 IP core
V3.0.0/V3.00a^
**Bit Description ECAT**^ **PDI**^ **Reset value**^
0 PDI function acknowledge by write:
0: Disabled
1: Enabled
r/- r/-^ IP core: depends^ on
configuration
Others: 0, later
EEPROM
(^1) ESC configuration area A loaded from
EEPROM:
0: not loaded
1: loaded
r/- r/-^0
(^2) PDI0 active:
0: PDI0 not active
1: PDI0 active
r/- r/-^
(^3) PDI0 configuration invalid:
0: PDI0 configuration ok
1: PDI0 configuration invalid
r/- r/-^
(^4) PDI SyncManager function acknowledge by
write:
0: Default, according to PDI function
acknowledge by write 0x014E[0]
1: Disabled
r/- r/-^ IP core: depends^ on
configuration
Others: 0
15:5 Reserved r/- r/- 0


```
slave controller – register description II- 43
```
### 2.6.6 PDI0 configuration (0x0150:0x0153)

The PDI0 configuration register 0x0150 and the extended PDI0 configuration registers 0x0152:0x0153
depend on the selected PDI0. The Sync/latch[3:0] PDI configuration register 0x0151 is independent of
the selected PDI0.

```
PDI number PDI name^ Configuration registers
```
0x0 4 Digital I/O (^) 0x0150 0x0152:0x0153
0x0 5 SPI slave (^) 0x0150 0x0152:0x0153
0x07 EtherCAT bridge (port 3) (^) 0x0150 0x0152:0x0153
0x08/0x0 9 Asynchronous microcontroller (^) 0x0150 0x0152:0x0153
0x0A/0x0B Synchronous microcontroller (^) 0x0150 0x0152:0x0153
0x0C/0x0D Multiplexed asynchronous
microcontroller
0x0150 0x0152:0x0153^
0x0E/0x0F Multiplexed synchronous
microcontroller
0x0150 0x0152:0x0153^
0x15 SPI master (^) 0x0150 0x0152:0x0153
0x80 On-chip bus (^) 0x0150 0x0152:0x0153
**DC sync/latch[3:0] configuration A 0**
- Sync/Latch configuration A (^0) 0x0151


II- 44 slave controller – register description

**2.6.6.1 Digital I/O (0x0150-0x0153)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
(^0) OUTVALID polarity:
0: Active high
1: Active low
r/- r/-^ IP core: 0^
Others: 0, later
EEPROM word A1[1:0]
(^1) OUTVALID mode:
0: Output event signaling
1: Process data watchdog trigger
(WD_TRIG) signaling on OUTVALID pin
(see SyncManager). Output data is
updated if watchdog is triggered.
Overrides 0x0150[7:6]
r/- r/-^
(^2) Unidirectional/bidirectional mode*:
0: Unidirectional mode: input/output
direction of pins configured individually
1: Bidirectional mode: all I/O pins are
bidirectional, direction configuration is
ignored
r/- r/-^ IP core: 1^
Others: 0, later
EEPROM word A1[2]
(^3) Watchdog behavior:
0: Outputs are reset immediately after
watchdog expires
1: Outputs are reset with next output event
that follows watchdog expiration
r/- r/-^ IP core: 0^
Others: 0, later
EEPROM word A1[3]
5:4 (^) Input DATA is sampled at
00: Start of frame^2
01: Rising edge of LATCH_IN
10: DC SYNC0 event^2
11: DC SYNC1 event^2
r/- r/-^ IP core: depends^ on
configuration
Others: 0, later
EEPROM word A1[5:4]
7:6 (^) Output DATA is updated at
00: End of frame
01: OUT_START (ET1150 only), else
reserved
10: DC SYNC0 event
11: DC SYNC1 event
If 0x0150[1]=1, output data is updated at
process data watchdog trigger event
(0x0150[7:6] are ignored)
r/- r/- IP core: depends^ on
configuration
Others: 0, later
EEPROM word A1[7:6]
* IP core: I/O direction depends on configuration, bidirectional mode is not supported.
**DC sync/latch[3:0] PDI configuration (0x0151) moved to chapter 2.6.6.9**
(^2) ET1200: LATCH_IN/SOF reflects start of start (SOF) if input data is sampled with SOF or DC SYNC events.


```
slave controller – register description II- 45
```
## Table 4: Digital I/O extended configuration (0x0152:0x0153)

```
ESC20 ET1100 ET1150 ET1200 IP core
[15:8]
```
**Bit Description ECAT**^ **PDI**^ **Reset value**^

(^) Digital I/Os are configured in pairs as inputs
or outputs:
0: Input
1: Output
NOTE: Reserved in bidirectional mode, set to 0.
Configuration bits for unavailable I/Os are
reserved, set EEPROM value to 0.
(^)
0 Direction of I/O[1:0] r/- r/- IP core: depends^ on
configuration
Others: 0, later
EEPROM word A 3
1 Direction of I/O[3:2]
2 Direction of I/O[5:4]
3 Direction of I/O[7:6]
4 Direction of I/O[9:8]
5 Direction of I/O[11:10]
6 Direction of I/O[13:12]
7 Direction of I/O[15:14]
8 Direction of I/O[17:16]
9 Direction of I/O[19:18]
10 Direction of I/O[21:20]
11 Direction of I/O[23:22]
12 Direction of I/O[25:24]
13 Direction of I/O[27:26]
14 Direction of I/O[29:2 8 ]
15 Direction of I/O[31:30]


II- 46 slave controller – register description

**2.6.6.2 SPI slave (0x0150-0x0153)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[3:2], [7:6] [7:6] [7:6] [7:6]
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
1:0 (^) SPI mode:
00: SPI mode 0
01: SPI mode 1
10: SPI mode 2
11: SPI mode 3
NOTE: SPI mode 3 is recommended for slave
sample code
NOTE: SPI status flag is not available in SPI
modes 0 and 2 with normal data out sample.
r/- r/-^ IP core: depends^ on
configuration
Others: 0, later
EEPROM word A1[7:0]
3:2 (^) SPI_IRQ output driver/polarity:
00: Push-pull active low
01: Open drain (active low)
10: Push-pull active high
11: Open source (active high)
r/- r/-^
4 SPI_SEL polarity:
0: Active low
1: Active high
r/- r/-^
5 MISO sample mode:
0: Normal sample (SPI_MISO and
SPI_MOSI are sampled at the same
SPI_CLK edge)
1: Late sample (SPI_MISO and SPI_MOSI
are sampled at different SPI_CLK
edges)
r/- r/-^
6 Address phase AL event request byte order:
0: First byte 0x0220, second 0x0221
1: First byte 0x0221, second 0x0220
NOTE: Third byte is always 0x0222.
r/- r/-^
(^7) SPI slave: Additional features:
0: disabled (only 0x0150[6:0])
1: enabled (0x0152:0x0153 available,
SEL_MISO/SEL_MOSI signals)
r/- r/-^
**DC sync/latch[3:0] PDI configuration (0x0151) moved to chapter 2.6.6.9**


```
slave controller – register description II- 47
```
## Table 5: SPI slave extended configuration (0x0152:0x0153)

```
ESC20 ET1100 ET1150 ET1200 IP core
[15:0] [15:0] V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
Extended SPI slave configuration features
available if 0x0150[7]=1, else fixed to 0x0000

```
1:0 Number of SPI MISO/MOSI channels:
00: 1 channel
01: 2 channel
10: 4 channel
11: 8 channel
```
```
r/- r/-^ IP core: 0^
Others: 0, later
EEPROM word A3
```
```
2 SEL_MISO wait state byte:
0: No wait state byte, pause between
select and first SPI_CLK
1: Wait state byte
```
```
r/- r/-^
```
```
5: 3 Reserved, set EEPROM value to 0 r/- r/-^
6 SPI MISO/MOSI direction:
0: Unidirectional
1: Bidirectional
```
```
r/- r/-^
```
```
15: 7 Reserved, set EEPROM value to 0 r/- r/-^
```

II- 48 slave controller – register description

**2.6.6.3 SPI master (0x0150-0x0153)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
1:0 (^) SPI mode:
00: SPI mode 0
01: SPI mode 1
10: SPI mode 2
11: SPI mode 3
NOTE: SPI mode 3 is recommended for slave
sample code
r/- r/-^ IP core: depends^ on
configuration
Others: 0, later
EEPROM word A1[7:0]
2 Unidirectional access order:
0: MISO at start, MOSI at end, for serial
I/O slaves
1: MISO/MOSI at start, for Beckhoff ESC
SPI slave PDI
r/- r/-^
3 Watchdog/SM deactivation behavior:
0: MOSI cycle with zero values
immediately after watchdog expires/SM
deactivation
1: MOSI cycle with zero values with next
output access start that follows
watchdog expiration/SM deactivation
r/- r/-^
4 SPI_SEL polarity:
0: Open drain (active low)
1: Open source (active high)
r/- r/-^
7:5 MISO sample delay (delay between
SPI_MISO sample edge and SPI_MOSI
sample edge in multiples of SPI_CLK period):
000: No delay (Normal sample)
001: 0.5 * SPI_CLK delay (Late sample)
010: 1.0 * SPI_CLK delay
011: 1.5 * SPI_CLK delay
100: 2.0 * SPI_CLK delay
101: 2.5 * SPI_CLK delay
110: 3.0 * SPI_CLK delay
111: 3.5 * SPI_CLK delay
r/- r/-^
**DC sync/latch[3:0] PDI configuration (0x0151) moved to chapter 2.6.6.9**


```
slave controller – register description II- 49
```
## Table 6: SPI master extended configuration (0x0152:0x0153)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
1:0 Number of SPI MISO/MOSI channels per
slave:
00: 1 channel
01: 2 channel
10: 4 channel
11: 8 channel
```
```
r/- r/-^ IP core: 0
Others: 0, later
EEPROM word A 3
```
```
3:2 Number of slaves:
00: 1 slave
01: 2 slave
10: 4 slave
11: 8 slave
NOTE: Number of slaves * number of channels
must not exceed 8.
```
```
r/- r/-^
```
```
5:4 Number of associated bytes per slave:
00: 1 byte (2/4/8 slaves only)
01: 2 bytes (2/4 slaves only)
10: 3 bytes (2 slaves only)
11: 4 bytes (2 slaves only)
NOTE: Setting is ignored if number of slaves=1.
Supported SyncManager length for 3 bytes/slave
is 6 byte only.
```
```
r/- r/-^
```
```
6 SPI MISO/MOSI direction:
0: Unidirectional
1: Bidirectional
```
```
r/- r/-^
```
```
7 Reserved, set EEPROM value to 0 r/- r/-^
```
11:8 Access start:
MISO MISO+MOSI MOSI
0000: SOF
0001: SOF WD_TRIGGER
0010: EOF
0011: Continuous
0100: Periodically every 10th cycle
0101: SYNC0
0110: SYNC0 SYNC1
0111: SYNC0 SYNC2
1000: SYNC0 SYNC3
1001: SYNC1 SYNC0
1010: SYNC1
1011: SYNC1 SYNC2
1100: SYNC2
1101: SYNC2 SYNC3
1110: SYNC3
1111: START_MISO START_MOSI

```
r/- r/-^
```

II- 50 slave controller – register description

```
Bit Description ECAT^ PDI^ Reset value^
15:12 SPI_CLK divider
CLK_PDI <= 100 MHz
SPI_CLK frequency =
PDI_CLK frequency /
divider
```
```
CLK_PDI > 100 MHz
SPI_CLK frequency =
PDI_CLK frequency / (2*divider)
```
```
Example for PDI_CLK=100MHz:
Divider Frequency Period
0x0: 1 100.000 MHz 10 ns
0x1: 2 50.000 MHz 20 ns
0x2: 3 33.333 MHz 30 ns
0x3: 4 25.000 MHz 40 ns
0x4: 5 20.000 MHz 50 ns
0x5: 6 16.667 MHz 60 ns
0x6: 7 14.286 MHz 70 ns
0x7: 8 12.500 MHz 80 ns
0x8: 9 11.111 MHz 90 ns
0x9: 10 10.000 MHz 100 ns
0xA 12 8.333 MHz 120 ns
0xB: 16 6.250 MHz 160 ns
0xC: 20 5.000 MHz 200 ns
0xD: 25 4.000 MHz 250 ns
0xE: 32 3.125 MHz 320 ns
0xF: 40 2.500 MHz 400 ns
```
```
r/- r/-^
```

```
slave controller – register description II- 51
```
**2.6.6.4 Asynchronous microcontroller (0x0150)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[7:4]
Bit Description ECAT^ PDI^ Reset value^
```
1: (^0) BUSY output driver/polarity:
00: Push-pull active low
01: Open drain (active low)
10: Push-pull active high
11: Open source (active high)
NOTE: Push-p ull: no CS → not BUSY (driven)
Open drain/source: no CS →
BUSY open
r/- r/-^ IP core: depends on
configuration
Others: 0, later
EEPROM word A1[3:0]
3: (^2) IRQ output driver/polarity:
00: Push-pull active low
01: Open drain (active low)
10: Push-pull active high
11: Open source (active high)
r/- r/-^
(^4) BHE/byte enable polarity:
0: Active low
1: Active high
r/- r/-^ IP core: 0
Others: 0, later
EEPROM word A1[7:4]
6: (^5) Reserved, set EEPROM value to 0 r/- r/-
(^7) RD polarity:
0: Active low
1: Active high
r/- r/-^
**DC sync/latch[3:0] PDI configuration (0x0151) moved to chapter 2.6.6.9**


II- 52 slave controller – register description

## Table 7: Asynchronous microcontroller extended configuration (0x0152:0x0153)

```
ESC20 ET1100 ET1150 ET1200 IP core
[15:1] [0]
V2.2.0/
V2.02a
[1]
V2.3.0/
V2.03a
[9, 4:3]
V4.0.0
[5]
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Read BUSY delay:
0: Normal read BUSY output
1: Delayed read BUSY output
r/- r/-^ IP core: 0^
Others: 0, later
EEPROM word A 3
(^1) Perform internal write at:
0: End of write access
1: Beginning of write access
r/- r/-^
(^2) Reserved, set EEPROM value to 0 r/- r/-
3 PDI external bus width factor:
0: x1 (8/16 bit)
1: x4 (32/64 bit)
r/- r/-^
4 Default busy state:
0: Not busy until access start detected
1: Busy after CS, until access finished
r/- r/-^
5 Compatible access time:
0: Normal access time (fast)
1: Extra delay, access time compatible
with ET1100
r/- r/-^
8:6 Reserved, set EEPROM value to 0 r/- r/-^
9 Read mode:
0: Use byte enable for read accesses
1: Ignore byte enable for read accesses,
always read full PDI width
r/- r/-^
15:10 (^) Reserved, set EEPROM value to 0 r/- r/-


```
slave controller – register description II- 53
```
**2.6.6.5 Synchronous microcontroller (0x0150-0x0153)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
1: (^0) TA output driver/polarity:
00: Push-pull active low
01: Open drain (active low)
10: Push-pull active high
11: Open source (active high)
NOTE: Push-p ull: no CS → no TA (driven)
Open drain/source: no CS → TA open
r/- r/-^ 0, later EEPROM word
A1[7:0]
3: (^2) IRQ output driver/polarity:
00: Push-pull active low
01: Open drain (active low)
10: Push-pull active high
11: Open source (active high)
r/- r/-^
(^4) BHE/byte enable polarity:
0: Active low
1: Active high
r/- r/-^
(^5) ADR(0) polarity:
0: Active high
1: Active low
r/- r/-^
(^6) Byte access mode:
0: BHE or byte enable mode
1: Transfer size mode
r/- r/-^
(^7) TS polarity:
0: Active low
1: Active high
r/- r/-^
**DC sync/latch[3:0] PDI configuration (0x0151) moved to chapter 2.6.6.9**


II- 54 slave controller – register description

## Table 8: Synchronous microcontroller extended configuration (0x0152:0x0153)

```
ESC20 ET1100 ET1150 ET1200 IP core
[7:0]
Bit Description ECAT^ PDI^ Reset value^
```
2:0 (^) Reserved, set EEPROM value to 0 r/- r/-
3 PDI external bus width factor:
0: x1 (8/16 bit)
1: x4 (32/64 bit)
r/- r/-^
4 Reserved, set EEPROM value to 0 r/- r/-^
5 Compatible access time:
0: Normal access time (fast)
1: Extra delay , access time compatible
with ET1100
r/- r/-^
7:6 Reserved, set EEPROM value to 0 r/- r/-
8 Write data valid:
0: Write data valid one clock cycle after CS
1: Write data valid together with CS
r/- r/-
9 Read mode:
0: Use byte selects for read accesses
1: Ignore byte selects for read accesses,
always read full PDI width
r/- r/-
(^10) CS mode:
0: Sample CS with rising edge of
CPU_CLK
1: Sample CS with falling edge of
CPU_CLK
r/- r/-^
(^11) TA/IRQ mode:
0: Update TA/IRQ with rising edge of
CPU_CLK
1: Update TA/IRQ with falling edge of
CPU_CLK
r/- r/-^
(^12) Transfer size encoding:
8 bit 16 bit 32 bit 64 bit
0: 01 10 00 11
1: 00 01 10 11
r/- r/-^
15:13 (^) Reserved, set EEPROM value to 0 r/- r/-


```
slave controller – register description II- 55
```
**2.6.6.6 Multiplexed asynchronous microcontroller (0x0150-0x0153)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
1:0 (^) BUSY output driver/polarity:
00: Push-pull active low
01: Open drain (active low)
10: Push-pull active high
11: Open source (active high)
NOTE: Push-p ull: no CS → not BUSY (driven)
Open drain/source: no CS →
BUSY open
r/- r/-^ 0, later EEPROM word
A1[7:0]
3:2 IRQ output driver/polarity:
00: Push-pull active low
01: Open drain (active low)
10: Push-pull active high
11: Open source (active high)
r/- r/-
(^4) BHE/byte enable polarity:
0: Active low
1: Active high
r/- r/-^
5 Reserved, set EEPROM value to 0 r/- r/-
6 Reserved, set EEPROM value to 0 r/- r/-
7 RD polarity:
0: Active low
1: Active high
r/- r/-
**DC sync/latch[3:0] PDI configuration (0x0151) moved to chapter 2.6.6.9**


II- 56 slave controller – register description

## Table 9: Multiplexed asynchronous microcontroller extended configuration (0x0152:0x0153)

```
ESC20 ET1100 ET1150 ET1200 IP core
```
```
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Read BUSY delay:
0: Normal read BUSY output
1: Delayed read BUSY output
r/- r/-^ 0, later EEPROM word
A3
(^1) Perform internal write at:
0: End of write access
1: Beginning of write access
r/- r/-^
(^2) ALE latch edge:
0: falling edge
1: rising edge
r/- r/-^
3 PDI external bus width factor:
0: x1 (8/16 bit)
1: x4 (32/64 bit)
r/- r/-^
4 Default busy state:
0: Not busy until access start detected
1: Busy after CS, until access finished
r/- r/-^
5 Compatible access time:
0: Normal access time (fast)
1: Extra delay , access time compatible
with ET1100
r/- r/-^
6 16 bit interface byte enable usage:
0: Use A(0) and BHE/byte enable(1)
1: Use byte enable(0) and byte enable(1)
r/- r/-^
8:7 Reserved, set EEPROM value to 0 r/- r/-^
9 Read mode:
0: Use byte enable for read accesses
1: Ignore byte enable for read accesses,
always read full PDI width
r/- r/-^
15:10 (^) Reserved, set EEPROM value to 0 r/- r/-


```
slave controller – register description II- 57
```
**2.6.6.7 EtherCAT bridge (port 3) (0x0150-0x0153)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[7: 2 ] [7:1]
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Bridge port physical layer:
0: EBUS
1: MII
r/- r/-^ 0, later EEPROM word
A1[7:0]
(^1) Initial port state:
0: Always closed (0x0100[15:14]=11)
1: Auto (0x0100[15:14]=00)
r/- r/-^
7:2 (^) Reserved, set EEPROM value to 0
**DC sync/latch[3:0] PDI configuration (0x0151) moved to chapter 2.6.6.9**


II- 58 slave controller – register description

## Table 10: EtherCAT bridge extended configuration (0x0152:0x0153)

```
ESC20 ET1100 ET1150 ET1200 IP core
[15: 0 ]
Bit Description ECAT^ PDI^ Reset value^
```
15:0 (^) Reserved, set EEPROM value to 0 r/- r/- 0, later EEPROM word
A 3


```
slave controller – register description II- 59
```
**2.6.6.8 On-chip bus (0x0150-0x0153)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
4 :0 (^) On-chip bus clock:
0: asynchronous
1-31: synchronous multiplication factor
(N * 25 MHz)
r/- r/-^ IP core: depends^ on
configuration
7:5 (^) On-chip bus:
000: Altera® Avalon®
001: AXI®
010: AMD® PLB v4.6
100: AMD OPB
others: reserved
r/- r/-^
**DC sync/latch[3:0] PDI configuration (0x0151) moved to chapter 2.6.6.9**

## Table 11: On-chip bus extended configuration (0x0152:0x0153)

```
ESC20 ET1100 ET1150 ET1200 IP core
V1.1.1/
V2.00a
Bit Description ECAT^ PDI^ Reset value^
```
1:0 (^) Read prefetch size (in cycles of PDI width):
0: 4 cycles
1: 1 cycle (typical)
2: 2 cycles
3: Reserved
r/- r/-^ IP core: depends^ on
configuration
7:2 (^) Reserved r/- r/-
10:8 (^) On-chip bus sub-type for AXI:
000: AXI3
001: AXI4
010: AXI4 LITE
others: reserved
r/- r/-^
15:11 (^) Reserved r/- r/-


II- 60 slave controller – register description

**2.6.6.9 DC sync/latch configuration A0 (0x0151)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
1: (^0) SYNC0/2 output driver/polarity:
00: Push-pull active low
01: Open drain (active low)
10: Push-pull active high
11: Open source (active high)
r/- r/-^ IP core:^10
Others: 00, later
EEPROM word A1[9:8]
2 SYNC0/LATCH0 configuration*:
0: LATCH input
1: SYNC output
r/- r/- IP core: 1^
Others: 0, later
EEPROM word A1[10]
(^3) SYNC0/2 mapped to AL event request
register 0x0220[2] /0x0220[24]:
0: Disabled
1: Enabled
r/- r/-^ IP core: depends^ on
configuration
Others: 0, later
EEPROM word A1[11]
5: (^4) SYNC1/3 output driver/polarity:
00: Push-pull active low
01: Open drain (active low)
10: Push-pull active high
11: Open source (active high)
r/- r/-^ IP core:^10
Others: 00, later
EEPROM word
A1[13:12]
(^6) SYNC1/LATCH1 configuration*:
0: LATCH input
1: SYNC output
r/- r/-^ IP core: 1^
Others: 0, later
EEPROM word A1[14]
(^7) SYNC1/3 mapped to AL event request
register 0x0220[3] /0x0220[25]:
0: Disabled
1: Enabled
r/- r/-^ IP core: depends^ on
configuration
Others: 0, later
EEPROM word A1[15]
* The IP core has concurrent SYNC[3:0] outputs and LATCH[3:0] inputs, independent of this configuration.


```
slave controller – register description II- 61
```
### 2.6.7 PDI0 user mode from ECAT (0x0158:0x0159)

**2.6.7.1 Digital I/O user mode from ECAT (0x0158:0x0159)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[15:8]^ V4.0.0[15:8]
```
```
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Enable:
0: Normal mode
1: User mode
r/w r/-^0
2:1 Reserved r/w r/-
3 Watchdog behavior
(refer to digital I/O 0x0150[3])
r/w r/-
5:4 Input DATA event
(refer to digital I/O 0x0150[5:4])
r/w r/-
7:6 Output DATA event
(refer to digital I/O 0x0150[7:6])
r/w r/-
15:8 (^) Reserved r/w r/-
**2.6.7.2 SPI master user mode from ECAT (0x0158:0x0159)**
ESC20 ET1100 **ET1150** ET1200 IP core
[15:8]
**Bit Description ECAT**^ **PDI**^ **Reset value**^
(^0) Enable:
0: Normal mode
1: User mode
r/w r/-^0
4:1 (^) Access start
(refer to SPI master 0x0152:0x0153[11:8])
r/w r/-^
(^5) MISO_VALID behavior:
0: Always perform MISO cycle. Set MISO
data=0 if MISO_VALID=0
1: Perform MISO cycle only if
MISO_VALID=1
(not available as SII EEPROM setting)
r/w r/-^
(^6) PDI error when MISO cycle start event
occurs:
0: No PDI error for MISO_VALID=0
1: PDI error for MISO_VALID=0
(not available as SII EEPROM setting)
r/w r/-^
(^7) Watchdog/SM deactivation behavior
(refer to SPI master 0x0152:0x0153[3])
r/w r/-^
15:8 (^) Reserved r/w r/-


II- 62 slave controller – register description

### 2.6.8 PDI0 user mode from PDI (0x015C:0x015D)

**2.6.8.1 Digital I/O user mode from PDI (0x015C:0x015D)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[15:8]^ V4.0.0[15:8]
```
```
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Enable:
0: Normal mode
1: User mode
r/w r/-^0
2:1 Reserved r/w r/-
3 Watchdog behavior
(refer to digital I/O 0x0150[3])
r/w r/-
5:4 Input DATA event
(refer to digital I/O 0x0150[5:4])
r/w r/-
7:6 Output DATA event
(refer to digital I/O 0x0150[7:6])
r/w r/-
15:8 (^) Reserved r/w r/-
NOTE: PDI0 user mode from ECAT 0x0158:0x0159 overrides this setting
**2.6.8.2 SPI slave user mode from PDI (0x015C:0x015D)**
ESC20 ET1100 **ET1150** ET1200 IP core
[15:8]^ V4.0.0[15:8]
**Bit Description ECAT**^ **PDI**^ **Reset value**^
(^0) Enable:
0: Normal mode
1: User mode
r/- r/w^0
5:1 (^) Reserved r/- r/w
6 Address phase AL event request byte order
(refer to SPI 0x0150[6])
r/- r/w
15:7 (^) Reserved r/- r/w


```
slave controller – register description II- 63
```
**2.6.8.3 SPI master user mode from PDI (0x015C:0x015D)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[15:8]
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Enable:
0: Normal mode
1: User mode
r/w r/-^0
4:1 (^) Access start
(refer to SPI master 0x0152:0x0153[11:8])
r/w r/-^
(^5) MISO_VALID behavior:
0: Always perform MISO cycle. Set MISO
data=0 if MISO_VALID=0
1: Perform MISO cycle only if
MISO_VALID=1
(not available as SII EEPROM setting)
r/w r/-^
(^6) PDI error when MISO cycle start event
occurs:
0: No PDI error for MISO_VALID=0
1: PDI error for MISO_VALID=0
(not available as SII EEPROM setting)
r/w r/-^
(^7) Watchdog/SM deactivation behavior
(refer to SPI master 0x015 0 [3])
r/w r/-^
15:8 (^) Reserved r/w r/-
NOTE: PDI0 user mode from ECAT 0x0158:0x0159 overrides this setting


II- 64 slave controller – register description

## 2.7 PDI1/ESC configuration area B

### 2.7.1 PDI1 control (0x0180)

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
7:0 (^) Process data interface:
0x00: Interface deactivated (no PDI)
0x04: Digital I/O
0x05: SPI slave
0x08: 16/64 bit asynchronous
microcontroller interface
0x09: 8/32 bit asynchronous
microcontroller interface
0x0A: 16/64 bit synchronous
microcontroller interface
0x0B: 8/32 bit synchronous microcontroller
interface
0x0C: 16/64 bit multiplexed asynchronous
microcontroller interface
0x0D: 8/32 bit multiplexed asynchronous
microcontroller interface
0x0E: 16/64 bit multiplexed synchronous
microcontroller interface
0x0F: 8/32 bit multiplexed synchronous
microcontroller interface
0x15: SPI master
0x80: On-chip bus
Others: Reserved
r/- r/-^ IP core: depends^ on
configuration
Others: 0, later
EEPROM word B0[7:0]

### 2.7.2 ESC configuration B0 (0x0181)

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
1:0 (^) PDI watchdog status selection for ESC DL
status 0x0110[1], ERR_LED, and
SyncManager deactivation delay:
00: PDI0
01: PDI1
10: PDI0 or PDI1
11: PDI0 and PDI1
r/- r/-^ IP core: depends^ on
configuration
Others: 0, later
EEPROM word B0[15:8]
7: (^2) Reserved, set EEPROM value to 0 r/- r/-


```
slave controller – register description II- 65
```
### 2.7.3 ESC configuration B5 (0x0182:0x0183)

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
5:0 (^) Private PDI RAM size in Kbyte.
Private area is located at the end of the
process data RAM, and only accessible by
PDI.
Valid values:

- 0 up to maximum ESC process data
    RAM in Kbyte
- maximum ESC process data RAM in
    Kbyte + 1: user RAM is also used as
    Private PDI RAM
- Other values: reserved

```
r/- r/- IP core: depends on
configuration
Others: 0, later
EEPROM word B 5
```
7:6 (^) PDI function acknowledge by write:
00: Disabled
01: Enabled for registers and SyncManager
buffers
10: Reserved
11: Enabled for registers only
r/- r/-^
(^8) MI link detection and configuration port 0
0: Disabled
1: Enabled
r/- r/-
9 MI link detection and configuration port 1
0: Disabled
1: Enabled
r/- r/-
10 MI link detection and configuration port 2
0: Disabled
1: Enabled
r/- r/-
11 MI link detection and configuration port 3
0: Disabled
1: Enabled
r/- r/-
15:12 (^) Reserved, set EEPROM value to 0 r/- r/-

### 2.7.4 ESC configuration B6 (0x0184:0x0185)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
15: (^0) Reserved, set EEPROM value to 0 r/- r/-


II- 66 slave controller – register description

### 2.7.5 ESC configuration B4 (0x0188:0x0189)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
5 : (^0) First PDI pin configured as general purpose
output (valid values 0-46).
Higher PDI pins are also general purpose
outputs, while lower PDI pins are used as
general purpose inputs.
NOTE: Some PDI pins might not be available for
general purpose IO, when they are used for other
functions.
r/- r/-^ IP core: depends^ on
configuration
Others: 0, later
EEPROM word B 4
6 GPIO direction:
0: Unidirectional
1: Bidirectional
r/- r/-
(^7) DC signal block position:
0: Next free byte
1: Before free byte
r/- r/-^
8 DC LATCH2/3 enable:
0: Disable
1: Enable
r/- r/-
(^9) DC SYNC0/1 enable:
0: Disable
1: Enable
r/- r/-^
(^10) DC SYNC2/3 enable:
0: Disable
1: Enable
r/- r/-^
11 LED_PDI 0 _ERR/LED_PDI 1 _ERR enable:
0: Disable
1: Enable
r/- r/-
15:12 (^) CPU_CLK_OUT2 and CPU_nRESET_OUT:
Frequency Period
0x0: Disabled -
0x1: 50.000 MHz 20 ns
0x2: 33.333 MHz 30 ns
0x3: 25.000 MHz 40 ns
0x4: 20.000 MHz 50 ns
0x5: 16.667 MHz 60 ns
0x6: 14.286 MHz 70 ns
0x7: 12.500 MHz 80 ns
0x8: 11.111 MHz 90 ns
0x9: 10.000 MHz 100 ns
0xA 8.333 MHz 120 ns
0xB: 6.250 MHz 160 ns
0xC: 5.000 MHz 200 ns
0xD: 4.000 MHz 250 ns
0xE: 3.125 MHz 320 ns
0xF: 2.500 MHz 400 ns
r/- r/-^


```
slave controller – register description II- 67
```
### 2.7.6 PDI1 information (0x018E:0x018F)

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
0 PDI register function acknowledge by write:
0: Disabled
1: Enabled
```
```
r/- r/-^ IP core: depends on
configuration
Others: 0, later
EEPROM
```
(^1) ESC configuration area B loaded from
EEPROM:
0: not loaded
1: loaded
r/- r/-^0
(^2) PDI1 active:
0: PDI1 not active
1: PDI1 active
r/- r/-^
(^3) PDI1 configuration invalid:
0: PDI1 configuration ok
1: PDI1 configuration invalid
r/- r/-^
(^4) PDI SyncManager function acknowledge by
write:
0: Default, according to PDI function
acknowledge by write 0x018E[0]
1: Disabled
r/- r/-^ IP core: depends^ on
configuration
Others: 0
15:5 Reserved r/- r/- 0


II- 68 slave controller – register description

### 2.7.7 PDI1 configuration (0x0190:0x0193)

The PDI1 configuration register 0x0190 and the extended PDI1 configuration registers 0x0192:0x0193
depend on the selected PDI1. The register 0x0191 is reserved.

```
PDI number PDI name^ Configuration registers
```
0x04 Digital I/O (^) 0x0190 0x0192:0x0193
0x05 SPI slave (^) 0x0190 0x0192:0x0193
0x08/0x09 Asynchronous microcontroller (^) 0x0190 0x0192:0x0193
0x0A/0x0B Synchronous microcontroller (^) 0x0190 0x0192:0x0193
0x0C/0x0D Multiplexed asynchronous
microcontroller
0x0190 0x0192:0x0193^
0x0E/0x0F Multiplexed synchronous
microcontroller
0x0190 0x0192:0x0193^
0x15 SPI master (^) 0x0190 0x0192:0x0193
0x80 On-chip bus (^) 0x0190 0x0192:0x0193
Please refer to chapter 2.6.6 (PDI0 configuration) for PDI1 configuration options.

### 2.7.8 PDI1 user mode from ECAT (0x0198:0x0199)

Please refer to chapter 2.6.7 (PDI0 user mode from ECAT) for PDI1 user mode options.

### 2.7.9 PDI1 user mode from PDI (0x019C:0x019D)

Please refer to chapter 2.6.8 (PDI0 user mode from PDI) for PDI1 user mode options.


```
slave controller – register description II- 69
```
## 2.8 Interrupts

### 2.8.1 ECAT event mask (0x0200:0x0201)

```
ESC20 ET1100 ET1150 ET1200 IP core
Optional
before
V2.4.0/
V2.04a
Bit Description ECAT^ PDI^ Reset value^
15:0 ECAT event masking of the ECAT event
request events for mapping into ECAT event
field of EtherCAT frames:
0: Corresponding ECAT event request
register bit is not mapped
1: Corresponding ECAT event request
register bit is mapped
```
```
r/w r/-^0
```
### 2.8.2 PDI0 AL event mask (0x0204:0x0207)

```
ESC20 ET1100 ET1150 ET1200 IP core
Optional
writable
Bit Description ECAT^ PDI^ Reset value^
31:0 AL event masking of the AL event request
register events for mapping to PDI0 IRQ
signal:
0: Corresponding AL event request
register bit is not mapped
1: Corresponding AL event request
register bit is mapped
```
```
r/- r/w^ 0x00FF:0xFF0F^
```
### 2.8.3 PDI1 AL event mask (0x020A:0x020D)

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
31:0 AL event masking of the AL event request
register events for mapping to PDI1 IRQ
signal:
0: Corresponding AL event request
register bit is not mapped
1: Corresponding AL event request
register bit is mapped
```
```
r/- r/w^ 0x00FF:0xFF0F^
```

II- 70 slave controller – register description

### 2.8.4 ECAT event request (0x0210:0x0211)

```
ESC20 ET1100 ET1150 ET1200 IP core
[1] [1] [1] [1] [1]
Bit Description ECAT^ PDI^ Reset value^
```
(^0) DC latch event:
0: No change on DC latch inputs
1: At least one change on DC latch inputs
(Bit is cleared by reading DC latch event
times from ECAT for ECAT-controlled latch
units, so that latch 0/1 status 0x09AE:0x09AF
indicates no event)
r/- r/-^0
(^1) Reserved r/- r/- 0
(^2) DL status event:
0: No change in DL status
1: DL status change
(Bit is cleared by reading out DL status
0x0110 or 0x0111 from ECAT)
r/- r/-^0
(^3) AL status event:
0: No change in AL status
1: AL status change
(Bit is cleared by reading out AL status
0x0130 or 0x0131 from ECAT)
r/- r/-^0

##### 4

##### 5

##### ...

##### 11

```
Mirrors values of each SyncManager status:
0: No SyncManager 0 event
1: SyncManager 0 event pending
0: No SyncManager 1 event
1: SyncManager 1 event pending
...
0: No SyncManager 7 event
1: SyncManager 7 event pending
```
```
r/- r/-^0
```
15:12 (^) Reserved r/- r/- 0


```
slave controller – register description II- 71
```
### 2.8.5 AL event request (0x0220:0x0223)

```
ESC20 ET1100 ET1150 ET1200 IP core
[ 7 :4]
[31:16]
```
```
[ 7 :5]
[31:16]
```
```
[ 7 :5]
[31:12]
```
```
[5:4]
V2.0.0/
V2.00a;
[6]
V2.3.0/
V2.03a
[25:24]
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
(^0) AL control event:
0: No AL control register change
1: AL control register has been written^3
(Bit is cleared by reading AL control register
0x0120 or 0x0121 from PDI)
r/- r/-^0
(^1) DC latch event:
0: No change on DC latch inputs
1: At least one change on DC latch inputs
(Bit is cleared by reading DC latch event
times from PDI, so that latch 0/1 status
0x09AE:0x09AF indicates no event. Available
if latch unit is PDI-controlled)
r/- r/-^0
(^2) State of DC SYNC0 (if register
0x0151[3] =1):
(Bit is cleared by reading SYNC0 status
0x098E from PDI, use only in acknowledge
mode)
r/- r/-^0
(^3) State of DC SYNC1 (if register
0x0151[7] =1):
(Bit is cleared by reading of SYNC1 status
0x098F from PDI, use only in acknowledge
mode)
r/- r/-^0
(^4) SyncManager activation register
(SyncManager register offset 0x6) changed:
0: No change in any SyncManager
1: At least one SyncManager changed
(Bit is cleared by reading SyncManager
activation registers 0x0806 etc. from PDI)
r/- r/-^0
(^5) EEPROM emulation:
0: No command pending
1: EEPROM command pending
(Bit is cleared by acknowledging the
command in EEPROM control/status register
0x0502:0x0503[10:8] from PDI)
r/- r/- 0
(^6) Watchdog process data:
0: Has not expired
1: Has expired
(Bit is cleared by reading watchdog status
process data 0x0440 from PDI)
r/- r/- 0
(^7) Reserved r/- r/- 0
(^3) AL control event is only generated if PDI emulation is turned off (ESC configuration A0 register 0x0141[0]=0)


II- 72 slave controller – register description

```
Bit Description ECAT^ PDI^ Reset value^
```
##### 8

##### 9

##### ....

##### 23

```
SyncManager event (SyncManager register
offset 0x5, bit [0] or [1]):
0: No SyncManager 0 event
1: SyncManager 0 event pending
0: No SyncManager 1 event
1: SyncManager 1 event pending
...
0: No SyncManager 15 event
1: SyncManager 15 event pending
```
```
r/- r/-^0
```
(^24) State of DC SYNC2:
(Bit is cleared by reading SYNC0 status
0x098C from PDI)
r/- r/-^0
(^25) State of DC SYNC3:
(Bit is cleared by reading of SYNC1 status
0x098D from PDI)
r/- r/-^0
31:26 (^) Reserved r/- r/- 0


```
slave controller – register description II- 73
```
## 2.9 Error counter

### 2.9.1 RX error counter (0x0300:0x0307)

Two bytes per port y (0x0300+y*2:0x0301+y*2):

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
7:0 Invalid frame counter of port y (counting is
stopped when 0xFF is reached).
```
```
r/
w(clr)
```
```
r/- 0
```
```
15:8 RX error counter of port y (counting is
stopped when 0xFF is reached).
```
```
r/
w(clr)
```
```
r/- 0
```
NOTE: Error counters 0x0300-0x030B, 0x0314-0x0317, and error code 0x0320-0x0327 are cleared if one of
the implemented RX error counters 0x0300-0x030B is written (preferably 0x0300). Write value is ignored (write 0).
Errors are only counted if the loop of the port is open.

### 2.9.2 Forwarded RX error counter (0x0308:0x030B)

One byte per port y (0x0308+y):

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
7:0 Forwarded error counter of port y (counting is
stopped when 0xFF is reached).
```
```
r/
w(clr)
```
```
r/- 0
```
NOTE: Error counters 0x0300-0x30B, 0x0314-0x0317, and error code 0x0320-0x0327 are cleared if one of the
implemented RX error counters 0x0300-0x030B is written (preferably 0x0300). Write value is ignored (write 0).
Errors are only counted if the loop of the port is open.

### 2.9.3 ECAT processing unit error counter (0x030C)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
7:0 ECAT processing unit error counter (counting
is stopped when 0xFF is reached). Counts
errors of frames passing the processing unit.
```
```
r/
w(clr)
```
```
r/- 0
```
NOTE: Error counter 0x030C is cleared if error counter 0x030C is written. Write value is ignored (write 0).

### 2.9.4 PDI0 error counter (0x030D)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
7:0 PDI 0 error counter (counting is stopped when
0xFF is reached). Counts if a PDI0 access
has an interface error.
```
```
r/
w(clr)
```
```
r/- 0
```
NOTE: Error counter 0x030D and error code 0x030E:0x030F are cleared if error counter 0x030D is written. Write
value is ignored (write 0).


II- 74 slave controller – register description

### 2.9.5 PDI0 error code (0x030E:0x030F)

**2.9.5.1 SPI slave error code (0x030E:0x030F)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[7:0]
V2.3.0/
V2.03a
[15:8]
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
Reasons for last PDI error r/- r/- 0
2:0 Number of SPI clock cycles of whole access
(modulo 8) causing PDI error
```
(^3) Busy violation during read access:
0: no error
1: error detected
(^4) Read termination missing:
0: no error
1: error detected
(^5) Access continued after read termination byte
0: no error
1: error detected
7:6 (^) 0x0 3 0E[8]=0 or not supported:
SPI command CMD[2:1] of access
causing PDI error.
0x030E[8]=1:
[SEL_MOSI:SEL_MISO] of access
causing PDI error.
(^8) Access type:
0: Normal access
1: SEL_MISO/SEL_MOSI access
12:9 reserved
(^13) SyncManager configuration not valid:
0: no error
1: configuration not valid
NOTE: always 0 if 0x030E[8]=0
(^14) Invalid combination of select signals:
0: no error
1: invalid combination
NOTE: always 0 if 0x030E[8]=0
(^15) Both SEL_MISO and SEL_MOSI detected,
but with too much skew:
0: no error
1: SEL_MISO or SEL_MOSI added too
late
NOTE: always 0 if 0x030E[8]=0
NOTE: Error counter 0x030D and error code 0x030E:0x030F are cleared if error counter 0x030D is written. Write
value is ignored (write 0).


```
slave controller – register description II- 75
```
**2.9.5.2 SPI master error code (0x030E:0x030F)**

```
ESC20 ET1100 ET1150 ET1200 IP core
```
```
Bit Description ECAT^ PDI^ Reset value^
Reasons for last PDI error r/- r/- 0
0 MISO cycle start event without MISO_VALID,
if enabled in SPI master user mode bit 6:
0: no error
1: error detected
1 MISO SyncManager configuration invalid:
0: no error
1: error detected
2 MOSI SyncManager configuration invalid:
0: no error
1: error detected
3 Start event occurred during MISO/MOSI
cycle:
0: no error
1: error detected
4 MOSI SyncManager configuration lost during
MOSI cycle:
0: no error
1: error detected
5 Invalid combination of number of slaves and
number of associated bytes per slave:
0: no error
1: error detected
6 Number of slaves * number of channels
exceeds 8:
0: no error
1: error detected
```
15:7 (^) Reserved
NOTE: Error counter 0x030D and error code 0x030E:0x030F are cleared if error counter 0x030D is written. Write
value is ignored (write 0).


II- 76 slave controller – register description

**2.9.5.3 Microcontroller error code (0x030E:0x030F)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[7:0]
V2.3.0/
V2.03a
[15:8]
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
Reasons for last PDI error r/- r/- 0
```
(^0) Busy violation during read access
0: no error
1: error detected
(^1) Busy violation during write access
0: no error
1: error detected
(^2) Addressing error for a read access
(odd address without BHE)
0: no error
1: error detected
NOTE: for 16 bit μController PDI only
(^3) Addressing error for a write access
(odd address without BHE)
0: no error
1: error detected
NOTE: for 16 bit μController PDI only
15 :4 Reserved
NOTE: Error counter 0x030D and error code 0x030E:0x030F are cleared if error counter 0x030D is written. Write
value is ignored (write 0).


```
slave controller – register description II- 77
```
**2.9.5.4 Avalon error code (0x030E:0x030F)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[0]
V3.0.0/
V3.00c
[15:1]
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
(^) Reasons for last PDI error r/- r/- 0
(^0) Both read and write signals active at the
same time
0: no error
1: error detected
(^1) Read or write access was aborted before it
finished:
0: no error
1: error detected
15 : (^2) Reserved
NOTE: Error counter 0x030D and error code 0x030E:0x030F are cleared if error counter 0x030D is written. Write
value is ignored (write 0).


II- 78 slave controller – register description

**2.9.5.5 AXI error code (0x030E:0x030F)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[15:0]
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
Reasons for last PDI error r/- r/- 0
0 AWVALID removed without AW_READY:
0: no error
1: error detected
1 WVALID removed without W_READY:
0: no error
1: error detected
2 ARVALID removed without AR_READY:
0: no error
1: error detected
3 AWSIZE too large:
0: no error
1: error detected
4 ARSIZE too large:
0: no error
1: error detected
```
(^5) Reserved
6 AWMAX_SIZE too large:
0: no error
1: error detected
7 ARMAX_SIZE too large:
0: no error
1: error detected
15:8 Reserved
NOTE: Error counter 0x030D and error code 0x030E:0x030F are cleared if error counter 0x030D is written. Write
value is ignored (write 0).


```
slave controller – register description II- 79
```
### 2.9.6 Lost link counter (0x0310:0x0303)

One byte per port y (0x0310+y):

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
7:0 Lost link counter of port y (counting is
stopped when 0xff is reached). Counts only if
port is open and loop is auto.
```
```
r/
w(clr)
```
```
r/- 0
```
NOTE: Lost link counters 0x0310-0x0313 are cleared if one of the implemented Lost link counters 0x0310-0x0313
is written (preferably 0x0310). Write value is ignored (write 0).

### 2.9.7 Extended RX error counter (0x0314:0x0317)

One byte per port y (0x0314+y):

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
7:0 Extended RX error counter (counting is
stopped when 0xFF is reached). Counts if
receive error occurs (even if port is closed).
ET1150:
Also counts link failure events if the ESC
does not accept the physical link (e.g., wrong
speed).
RX error code 0x0320+y indicates the reason
of the first event causing extended RX error
increment to 1.
```
```
r/- r/- 0
```
NOTE: Error counters 0x0300-0x030B, 0x0314-0x0317, and RX error code 0x0320-0x0327 are cleared if one of
the implemented error counters 0x0300-0x030B is written (preferably 0x0300). Write value is ignored (write 0).


II- 80 slave controller – register description

### 2.9.8 RX error code (0x0320:0x0327)

Two bytes per port y (0x0320+y*2:0x0321+y*2):

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
Current link error code of port y if
Extended RX error counter 0x0314+y=0
else
RX error code/link error code causing the first
increment of extended RX error counter
0x0314+y after it was cleared
```
```
r/- r/- 0
```
```
7:0 General error code
15:8 ESC specific error code details
```
NOTE: RX error code correlates with extended RX error counter (0x0314:0x0317). Error counters 0x0300-
0x030B, 0x0314-0x0317, and error code 0x0320-0x0327 are cleared if one of the implemented error counters
0x0300-0x030B is written (preferably 0x0300). Write value is ignored (write 0).


```
slave controller – register description II- 81
```
## Table 12: General RX error codes

```
Code Description Details
available
Link error codes
0x20 RX_CLK too fast (Ethernet)
0x21 RX_CLK too slow (Ethernet)
0x22 RX_CLK other error (Ethernet)
0x23 TX_CLK too fast (Ethernet)
0x24 TX_CLK too slow (Ethernet)
0x25 TX_CLK other error (Ethernet)
0x28 Enhanced link detection prevents link
0x 29 MI link detection prevents link (Ethernet)
0x2A Unsupported link speed or half duplex
RX error codes
0x30 False carrier (Ethernet) / idle decode error (EBUS) for EBUS
0x31 False carrier Extend (RGMII)
0x32 Bad SSD
0x40 RX_ER in frame (Ethernet) / frame decode error (EBUS) for EBUS
0x50 FIFO overrun
0x51 FIFO underrun
0x52 FIFO other error
0x58 Frame dropped (e.g., inter-frame-gap/IFG too short)
0x60 Checksum error (without alignment nibble)
0x61 Forwarded error (checksum error with alignment nibble), only detected for
closed ports
0x62 Frame without SFD
0x63 Frame too long (> 2 Kbyte, with/without SFD)
0x70 Frame shorter than expected
0x71 Frame longer than expected
0x72 Circulating frame (circulating frame bit=1 and port 0 automatically closed)
0x77 Other EtherCAT processing unit error
0x78 Non-EtherCAT frame received while DL control register 0x0100[0]=1
```
NOTE: RX error codes from 0x70-0x78 are only counted for the inbound port of the EtherCAT processing unit.


II- 82 slave controller – register description

### 2.9.9 PDI1 error counter (0x0340)

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
7:0 PDI error counter (counting is stopped when
0xFF is reached). Counts if a PDI access has
an interface error.
```
```
r/
w(clr)
```
```
r/- 0
```
NOTE: Error counter 0x0340 and error code 0x0341 are cleared if error counter 0x0340 is written. Write value is
ignored (write 0).

### 2.9.10 PDI1 error code (0x0341:0x0342)

Please refer to chapter 2.9.5 (PDI0 error code) for PDI1 error codes.


```
slave controller – register description II- 83
```
## 2.10 Watchdog

### 2.10.1 Watchdog divider (0x0400:0x0401)

```
ESC20 ET1100 ET1150 ET1200 IP core
Optional
writable
Bit Description ECAT^ PDI^ Reset value^
15:0 Watchdog divider: Number of 25 MHz tics
(minus 2) that represent the basic watchdog
increment. (Default value is 100μs = 2498)
```
```
r/w r/- 0x09C2^
```
### 2.10.2 Watchdog time PDI0 (0x0410:0x0411)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
15:0 Watchdog time PDI0: number of basic
watchdog increments
(default value with watchdog divider 100μs
means 100ms watchdog)
```
```
r/w r/- 0x03E8^
```
Watchdog is disabled if watchdog time is set to 0x0000. Watchdog starts counting again with every
PDI0 access.

### 2.10.3 Watchdog time PDI1 (0x0412:0x0413)

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
15:0 Watchdog time PDI1: number of basic
watchdog increments
(default value with watchdog divider 100μs
means 100ms watchdog)
```
r/w (^) r/- 0x03E8
Watchdog is disabled if watchdog time is set to 0x0000. Watchdog starts counting again with every
PDI1 access.

### 2.10.4 Watchdog time process data (0x0420:0x0421)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
15:0 Watchdog time process data: number of
basic watchdog increments
(default value with watchdog divider 100μs
means 100ms watchdog)
```
```
r/w r/- 0x03E8^
```
There is one watchdog for all SyncManagers. Watchdog is disabled if watchdog time is set to 0x0000.
Watchdog starts counting again with every write access to SyncManagers with watchdog trigger
enable bit set.


II- 84 slave controller – register description

### 2.10.5 Watchdog status process data (0x0440:0x0441)

```
ESC20 ET1100 ET1150 ET1200 IP core
(w ack) (w ack) (w ack)
Bit Description ECAT^ PDI^ Reset value^
0
Watchdog status of process data (triggered
by SyncManagers)
0: Watchdog process data expired
1: Watchdog process data is active or
disabled
```
```
r/- r/^
(w ack)*
```
```
0
```
15:1 (^) Reserved r/- r/
(w ack)*
0
* PDI register function acknowledge by write command is disabled: reading this register from PDI clears AL event
request 0x0220[6]. Writing to this register from PDI is not possible. Default if feature is not available.
PDI register function acknowledge by write command is enabled: Writing this register from PDI clears AL event
request 0x0220[6]. Writing to this register from PDI is possible; write value is ignored (write 0).

### 2.10.6 Watchdog counter process data (0x0442)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
7:0 Watchdog counter process data (counting is
stopped when 0xFF is reached). Counts if
process data watchdog expires.
```
```
r/
w(clr)
```
```
r/- 0
```
NOTE: Watchdog counters 0x0442-0x0444 are cleared if one of the watchdog counters 0x0442-0x0444 is written.
Write value is ignored (write 0).

### 2.10.7 Watchdog counter PDI0 (0x0443)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
7:0 Watchdog PDI 0 counter (counting is stopped
when 0xFF is reached). Counts if PDI 0
watchdog expires.
```
```
r/
w(clr)
```
```
r/- 0
```
NOTE: Watchdog counters 0x0442-0x0444 are cleared if one of the watchdog counters 0x0442-0x0444 is written.
Write value is ignored (write 0).

### 2.10.8 Watchdog counter PDI1 (0x0444)

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
7:0 Watchdog PDI1 counter (counting is stopped
when 0xFF is reached). Counts if PDI1
watchdog expires.
```
```
r/
w(clr)
```
```
r/- 0
```
NOTE: Watchdog counters 0x0442-0x0444 are cleared if one of the watchdog counters 0x0442-0x0444 is written.
Write value is ignored (write 0).


## 2.11 SII EEPROM interface slave controller – register description II- IX

### 2.10.9 Watchdog status PDI (0x0448)

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
0
Watchdog status of PDI0:
0: Watchdog PDI0 expired
1: Watchdog PDI0 is active or disabled
```
```
r/- r/-^0
```
##### 1

```
Watchdog status of PDI1:
0: Watchdog PDI1 expired
1: Watchdog PDI1 is active or disabled
```
```
r/- r/-^0
```
7 :2 (^) Reserved r/- r/- 0
NOTE: The Watchdog status for the PDI0 can be read in the DL status register 0x0110[1].


II- 86 slave controller – register description

**2.11 SII EEPROM interface**

## Table 13: SII EEPROM interface register overview

```
Register address Length^
(byte)
```
```
Description
```
0x0500 (^1) EEPROM ECAT access state
0x0501 (^1) EEPROM PDI access state
0x0502:0x0503 (^2) EEPROM control/status
0x0504:0x0507 (^4) EEPROM address
0x0508:0x050F (^) 4/8 EEPROM data
EtherCAT controls the SII EEPROM interface if EEPROM configuration register 0x0500[0]=0 and
EEPROM PDI access register 0x0501[0]=0, otherwise PDI controls the EEPROM interface.
In EEPROM emulation mode, the PDI executes pending EEPROM commands. The PDI has access to
some registers while the EEPROM interface is busy.

### 2.11.1 EEPROM ECAT access state (0x0500)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
(^0) EEPROM control is offered to PDI:
0: no
1: yes (PDI has EEPROM control)
r/w r/-^0
(^1) Force ECAT access:
0: Do not change bit 0x0501[0]
1: Reset bit 0x 0501 [ 0 ] to 0
r/w r/-^0
7:2 (^) Reserved, write 0 r/- r/- 0

### 2.11.2 EEPROM PDI access state (0x0501)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Access to EEPROM:
0: PDI releases EEPROM access
1: PDI takes EEPROM access (PDI has
EEPROM control)
r/- r/(w)^0
7:1 (^) Reserved, write 0 r/- r/- 0
NOTE: r/(w): write access is only possible if (0x0500[0]=1 or 0x0501[0]=1) and 0x0500[1]=0.


```
slave controller – register description II- 87
```
### 2.11.3 EEPROM control/status (0x0502:0x0503)

```
ESC20 ET1100 ET1150 ET1200 IP core
[7, 4:1] [4:1] [4:1] [ 3 :1]
Bit Description ECAT^ PDI^ Reset value^
```
(^0) ECAT write enable*^2 :
0: Write requests are disabled
1: Write requests are enabled
This bit is always 1 if PDI has EEPROM control.
r/(w) r/-^0
2 :1 (^) Reserved, write 0 r/- r/- 0
(^3) EEPROM availability:
0: present (EEPROM_CLK high)
1: not present (EEPROM_CLK low)
r/- r/-^0
(^4) Reserved, write 0 r/- r/- 0
(^5) EEPROM emulation:
0: Normal operation (I²C interface used)
1: PDI emulates EEPROM (I²C not used)
r/- r/-^ IP core:^
depends on
configuration
Others: 0
(^6) Supported number of EEPROM read bytes:
0: 4 bytes
1: 8 bytes
r/- r/-^ ET1100/ET1150:
1
ET1200: 1
Others: 0
(^7) Selected EEPROM Algorithm:
0: 1 address byte (1Kbit – 16Kbit EEPROMs)
1: 2 address bytes (32Kbit – 4 Mbit EEPROMs)
r/- r/-^ ESC20: 0*^1
IP core:
depending on
PROM_SIZE and
features
Others: PIN
EEPROM size
10:8 (^) Command register*2:
Write: initiate command.
Read: currently executed command
Commands:
000: No command/EEPROM idle (clear error bits)
001: Read
010: Write
100: Reload
Others: reserved/invalid commands (do not issue)
EEPROM emulation only: after execution, PDI
acknowledges current command by writing command
value of currently executed command, to indicate
operation is ready.
r/(w) r/(w)^
r/[w]
0
(^11) Checksum error in ESC configuration area:
0: Checksum ok
1: Checksum error
EEPROM emulation only: PDI writes 1 if a CRC failure
has occurred for a reload command.
r/- r/-^
r/[w]
0
(^12) EEPROM loading status:
0: EEPROM loaded, device information ok
1: EEPROM not loaded, device information not
available (EEPROM loading in progress or
finished with a failure)
r/- r/-^0
(^13) Error acknowledge/command*^3 :
0: No error
1: Missing EEPROM acknowledge or invalid
command
EEPROM emulation only: PDI writes 1 if a temporary
failure has occurred.
r/- r/-^
r/[w]
0


II- 88 slave controller – register description

```
Bit Description ECAT^ PDI^ Reset value^
```
(^14) Error write enable*^3 :
0: No error
1: Write command without write enable
r/- r/-^0
(^15) Busy:
0: EEPROM interface is idle
1: EEPROM interface is busy
r/- r/-^0
NOTE: r/(w): write access depends upon the assignment of the EEPROM interface (ECAT/PDI). Write access is
blocked if EEPROM interface is busy (0x0502[15]=1).
NOTE: r/[w]: EEPROM emulation only: write access is possible if EEPROM interface is busy (0x0502[15]=1). PDI
acknowledges pending commands by writing a 1 into the corresponding command register bits (0x0502[10:8]).
General/temporary errors can be indicated by writing a 1 into the error bit 0x0502[13], CRC errors for Reload
command can be indicated by writing a 1 into the error bit 0x0502[11]. Acknowledging clears AL event request
0x0220[5].
*^1 ESC20: configurable with pin EEPROM SIZE, but not readable in this register.
*^2 Write enable bit 0 is self-clearing at the SOF of the next frame, command bits [10:8] are self-clearing after the
command is executed (EEPROM Busy ends). Writing “000” to the command register will also clear the error bits
[14:13]. Command bits [10:8] are ignored if error acknowledge/command is pending (bit 13).
*^3 Error bits are cleared by writing “000” (or any valid command) to command register bits [10:8].


```
slave controller – register description II- 89
```
### 2.11.4 EEPROM address (0x0504:0x0507)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
31:0 (^) EEPROM address
0: First word (= 16 bit)
1: Second word
Actually used EEPROM address bits:
[9:0]: EEPROM size up to 16 Kbit
[17:0]: EEPROM size 32 Kbit – 4 Mbit
[3 1 :0]: EEPROM emulation
r/(w) r/(w)^0
NOTE: r/(w): write access depends upon the assignment of the EEPROM interface (ECAT/PDI). Write access is
blocked if EEPROM interface is busy (0x0502[15]=1).

### 2.11.5 EEPROM data (0x0508:0x050F)

```
ESC20 ET1100 ET1150 ET1200 IP core
[63:32] [63:32]
Bit Description ECAT^ PDI^ Reset value^
```
15:0 (^) EEPROM write data (data to be written to
EEPROM) or
EEPROM read data (data read from
EEPROM, lower bytes)
r/(w) r/(w)^
r/[w]
0
63:16 (^) EEPROM read data (data read from
EEPROM, higher bytes)
r/- r/-^
r/[w]
0
NOTE: r/(w): write access depends upon the assignment of the EEPROM interface (ECAT/PDI). Write access is
blocked if EEPROM interface is busy (0x0502[15]=1).
NOTE: r/[w]: write access for EEPROM emulation if read or reload command is pending. See the following
information for further details:


II- 90 slave controller – register description

**2.11.5.1 EEPROM emulation with 32 bit EEPROM data register (0x0502[6]=0)**

Write access to the EEPROM data register 0x0508:0x050B is possible if the EEPROM interface is
busy (0x0502[15]=1). PDI places EEPROM read data in this register before the pending EEPROM
read command is acknowledged (writing to 0x0502[10:8]). For a Reload command, fill the EEPROM
data register with the values shown in the following table before acknowledging the command. These
values are automatically transferred to the designated registers after the Reload command is
acknowledged:

## Table 14: EEPROM emulation reload data for 32 bit data register (0x0508:0x050B)

```
ESC20 ET1100 ET1150 ET1200 IP core
[27:21]
V2.4.3/
V2.04d
Bit Description ECAT^ PDI^ Reset value^
```
15:0 (^) Configured station alias
(NVRAM word 4[15:0], reloaded into
0x0012[15:0])
r/- r/[w] 0
(^16) Enhanced link detection for all ports
(NVRAM word 0[ 9 ], reloaded into 0x0141[1])
r/- r/[w] 0
20:17 (^) Enhanced link detection for individual ports
(NVRAM word 0[15: 12 ], reloaded into
0x0141[7:4])
r/- r/[w] 0
24:21 ESC DL configuration
(NVRAM word 5[7:4], loaded into register
0x0100[23:20])
r/- (^) r/[w] 0
27:25 (^) FIFO size reduction (NVRAM word 5[ 11 : 9 ],
loaded into ESC DL control register
0x0100[18:16]):
000: FIFO size set to 7
001: FIFO size set to 6
010: FIFO size set to 5
011: FIFO size set to 4
100: FIFO size set to 3
101: FIFO size set to 2
110: FIFO size set to 1
111: FIFO size set to 0
NOTE: This value sets the ESC DL control
register only at the first EEPROM loading
r/- r/[w]^0
31 :28 (^) Reserved, write 0 r/- r/[w] 0
NOTE: r/[w]: write access for EEPROM emulation if read or reload command is pending.


```
slave controller – register description II- 91
```
**2.11.5.2 EEPROM emulation with 64 bit EEPROM data register (0x0502[6]=1)**

Write access to the EEPROM data register 0x0508:0x050F is possible if the EEPROM interface is
busy (0x0502[15]=1). PDI places EEPROM read data in this register before the pending EEPROM
read command is acknowledged (writing to 0x0502[10:8]). For Reload command, get EEPROM
address register value, place four EEPROM words beginning with the word at EEPROM address in
the EEPROM data register. acknowledge the Reload command. Check if the Reload command is still
pending, read the requested EEPROM address and place the data in the EEPROM data register.
Iterate until the Reload command is not pending anymore. The data is automatically transferred to the
designated registers when the Reload command is finished, and if the CRC is correct (or overridden
with 0x88A4).

## Table 15: EEPROM emulation reload data for 64 bit data register (0x0508:0x050F)...........................

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
63:0 (^) Four EEPROM words starting at EEPROM
address 0x0504:0x0507
r/- r/[w]^0
NOTE: r/[w]: write access for EEPROM emulation if read or reload command is pending.


II- 92 slave controller – register description

## 2.12 PHY management interface

## Table 16: PHY management interface register overview

```
Register address Length^
(byte)
```
```
Description
```
0x0510:0x0511 (^2) PHY control/status
0x0512 (^1) PHY address
0x0513 (^1) PHY register address
0x0514:0x0515 (^2) PHY data
0x0516 (^1) PHY ECAT access state
0x0517 (^1) PHY PDI access state
0x0518:0x051B (^4) PHY port status
ECAT controls the PHY management interface if PHY management PDI access register 0x0517[0]=0 or if 0x0517
is not available, otherwise PDI controls the PHY management interface.
Exception for ET1100: PDI controls the PHY management interface if Transparent mode is enabled.


```
slave controller – register description II- 93
```
### 2.12.1 PHY control/status (0x0510:0x0511)

```
ESC20 ET1100 ET1150 ET1200 IP core
[10, 13] [10, 13] [10, 13] [13]
V2.0.0/
V2.00a
[10]
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Write enable*:
0: Write disabled
1: Write enabled
This bit is always 1 if PDI has MI control.
ET1100-0000/-0001 exception:
bit is not always 1 if PDI has MI control, and
bit is writable by PDI.
r/(w) r/- 0
1 Management interface can be controlled by
PDI (registers 0x0516-0x0517):
0: Only ECAT control
1: PDI control possible
r/- r/-^ IP core^ since
V2.0.0/V2.00a: 1
ET1150: 1
Others: 0
2 MI link detection and configuration:
0: Disabled for all ports
1: Enabled for at least one MII port, refer
to PHY port status (0x0518 ff.) for
details
r/- r/- IP core: depends^ on
configuration
Others: 0
7 :3 PHY address of port 0
(this is equal to the PHY address offset, if the
PHY addresses are consecutive)
ET1150, IP core since V3.0.0/3.00c:
Translation 0x0512[7]=0:
Register 0x0510[7:3] shows PHY address of
port 0
Translation 0x0512[7]=1:
Register 0x0510[7:3] shows the PHY address
which will be used for port 0-3 as requested
by 0x0512[4:0] (valid values 0-3)
r/- r/- ET1100/ET1150/
ET1200:
PHYAD_OFF
IP core: depends on
configuration
Others: 0


II- 94 slave controller – register description

```
Bit Description ECAT^ PDI^ Reset value^
```
10 :8 (^) Command register*:^
Write: Initiate command.
Read: Currently executed command
Clause 22 commands:
000: No command/MI idle (clear error bits)
001: Read
010: Write
011: Reserved/invalid command (do not
issue)
Clause 45 commands
(available if 0x0510[12]=1):
100: Set address
101: Read
110: Write
111: Read with post increment
r/(w) r/(w)^0
(^11) Reserved, write 0 r/- r/- 0
(^12) Clause 45 command availability:
0: Not supported
1: Supported
r/- r/-^ IP core^ since V4.0.0: 1^
ET1150: 1
Others: 0
(^13) Read error:
0: No read error
1: Read error occurred (PHY or register
not available)
Cleared by writing to register 0x0511.
r/(w) r/(w) 0
(^14) Command error:
0: Last command was successful
1: Invalid command or write command
without write enable
Cleared by executing a valid command or by
writing “0 0 0” to command register bits [ 10 :8].
r/- r/-^0
(^15) Busy:
0: PHY management interface is idle
1: PHY management interface is busy
r/- r/-^0
NOTE: r/ (w): write access depends on assignment of MI (ECAT/PDI). Write access is blocked if management
interface is busy (0x0510[15]=1).
* Write enable bit 0 is self-clearing at the SOF of the next frame, command bits [10:8] are self-clearing after the
command is executed (Busy ends). Writing “000” to the command register will also clear the error bits [14:13].
The command bits are cleared after the command is executed.


```
slave controller – register description II- 95
```
### 2.12.2 PHY address (0x0512)

```
ESC20 ET1100 ET1150 ET1200 IP core
[7] [7] [7] [7]
V3.0.0/
V3.00c
Bit Description ECAT^ PDI^ Reset value^
4:0 Target PHY address
Translation 0x0512[7]=0:
0-3: Target PHY addresses 0-3 are used to
access the PHYs at port 0-3, when the
PHY addresses are properly
configured
4-31: The configured PHY address of port 0
(PHY address offset) is added to the
Target PHY address values 4- 31
when accessing a PHY
```
```
Translation 0x0512[7]=1:
0-31: Target PHY addresses is used when
accessing a PHY without translation
```
```
r/(w) r/(w)^0
```
```
6:5 Reserved, write 0 r/- r/- 0
7 Target PHY address translation:
0: Enabled
1: Disabled
Refer to 0x0512[4:0] and 0x0510[7:3] for
details.
```
```
r/(w) r/(w)^0
```
NOTE: r/(w): write access depends on assignment of MI (ECAT/PDI). Write access is blocked if management
interface is busy (0x0510[15]=1).

### 2.12.3 PHY register address (0x0513)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
4:0 Address of PHY register that shall be
read/written
```
r/(w) (^) r/(w) 0
7:5 Reserved, write 0 r/- r/- 0
NOTE: r/(w): write access depends on assignment of MI (ECAT/PDI). Write access is blocked if management
interface is busy (0x0510[15]=1).

### 2.12.4 PHY data (0x0514:0x0515)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
15:0 PHY read/write data r/(w) r/(w) 0
```
NOTE: r/(w): write access depends on assignment of MI (ECAT/PDI). Write access is blocked if management
interface is busy (0x0510[15]=1).


II- 96 slave controller – register description

### 2.12.5 PHY ECAT access state (0x0516)

```
ESC20 ET1100 ET1150 ET1200 IP core
[7:1] [0]
V2.0.0/
V2.00a
[7:3]
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Access to PHY management:
0: ECAT enables PDI takeover of PHY
management interface
1: ECAT claims exclusive access to PHY
management interface
r/(w) r/-^0
7:1 (^) Reserved, write 0 r/- r/- 0
NOTE: r/(w): write access is only possible if 0x0517[0]=0.

### 2.12.6 PHY PDI access state (0x0517)

```
ESC20 ET1100 ET1150 ET1200 IP core
V2.0.0/
V2.00a
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Access to PHY management:
0: ECAT has access to PHY management
1: PDI has access to PHY management
r/- r/(w)^0
(^1) Force PDI access state:
0: Do not change bit 0x0517[0]
1: Reset bit 0x 0517 [ 0 ] to 0
r/w r/-^0
7:2 (^) Reserved, write 0 r/- r/- 0
NOTE: r/(w): assigning access to PDI (bit 0 = 1) is only possible if 0x0516[0]=0 and 0x0517[1]=0. The SII
EEPROM must be loaded (0x0110[0]=1) as well for IP cores before V3.0.0/V3.00c.


```
slave controller – register description II- 97
```
### 2.12.7 PHY port status (0x0518:0x051B)

One byte per port y (0x0518+y):

```
ESC20 ET1100 ET1150 ET1200 IP core
[4:0]
V2.0.0/
V2.00a;
[5]
V2.0.2/
V2.02a
[6]
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Physical link status (PHY status register 1. 2 ):
0: No physical link
1: Physical link detected
r/- r/-^0
(^1) Link status (link speed, Full Duplex, auto
negotiation checked):
0: No link
1: Link detected
r/- r/-^0
(^2) Link status error:
0: No error
1: Link error, link inhibited
r/- r/-^0
(^3) Read error:
0: No read error occurred
1: A read error has occurred
Cleared by writing any value to at least one
of the PHY port y status registers.
r/(w/clr) r/(w/clr)^0
(^4) Link partner error:
0: No error detected
1: Link partner error
r/- r/-^0
(^5) PHY configuration updated:
0: No update
1: PHY configuration was updated
Cleared by writing any value to at least one
of the PHY port y status registers.
r/(w/clr) r/(w/clr)^0
6 MI link detection and configuration:
0: Configuration for this port according to
0x0510[2]
1: Disabled for this port
r/- r/-^0
(^7) Reserved r/- r/- 0
NOTE: r/(w): write access depends on assignment of MI (ECAT/PDI). This register requires MI link detection and
configuration being enabled for the specific port (0x0510[2]=1 and (0x0518+y)[6]=0), otherwise the status is not
reliable.


II- 98 slave controller – register description

## 2.13 FMMU

In the address range 0x0600:0x06FF, 16 bytes are used per FMMU y (0x0600+y*16:0x060F+y*16).
Throughout this chapter, the register addresses for FMMU 0 are shown.

## Table 17: FMMU register overview........................................................................................................

```
Register address offset Length^
(byte)
```
```
Description
```
+0x0:0x3 (^4) Logical start address
+0x4:0x5 (^2) Length
+0x6 (^1) Logical start bit
+0x7 (^1) Logical stop bit
+0x8:0x9 (^2) Physical start address
+0xA (^1) Physical start bit
+0xB (^1) Type
+0xC (^1) Activate
+0xD:0xF (^3) Reserved

### 2.13.1 FMMU logical start address (0x0600:0x0603)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
31:0 Logical start address within the EtherCAT
address space.
```
```
r/w r/- 0
```
### 2.13.2 FMMU length (0x0604:0x0605)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
15:0 Offset from the first logical FMMU byte to the
last FMMU byte + 1 (e.g., if two bytes are
used, then this parameter shall contain 2)
```
```
r/w r/- 0
```
### 2.13.3 FMMU logical start bit (0x0606)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
2:0 Logical starting bit that shall be mapped (bits
are counted from least significant bit 0 to
most significant bit 7)
```
```
r/w r/- 0
```
```
7:3 Reserved, write 0 r/- r/- 0
```
### 2.13.4 FMMU logical stop bit (0x0607)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
2:0 Last logical bit that shall be mapped (bits are
counted from least significant bit 0 to most
significant bit 7)
```
```
r/w r/- 0
```
```
7:3 Reserved, write 0 r/- r/- 0
```

```
slave controller – register description II- 99
```
### 2.13.5 FMMU physical start address (0x0608:0x0609)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
15:0 Physical start address (mapped to logical
start address)
```
```
r/w r/- 0
```
### 2.13.6 FMMU physical start bit (0x060A)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
2:0 Physical starting bit as target of logical start
bit mapping (bits are counted from least
significant bit 0 to most significant bit 7)
```
```
r/w r/- 0
```
```
7:3 Reserved, write 0 r/- r/- 0
```
### 2.13.7 FMMU type (0x060B)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
(^0) 0: Ignore mapping for read accesses
1: Use mapping for read accesses
r/w r/-^0
(^1) 0: Ignore mapping for write accesses
1: Use mapping for write accesses
r/w r/-^0
7:2 (^) Reserved, write 0 r/- r/- 0

### 2.13.8 FMMU activate (0x060C)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
(^0) 0: FMMU deactivated
1: FMMU activated. FMMU checks
logically addressed blocks to be
mapped according to configured
mapping
r/w r/-^0
7:1 (^) Reserved, write 0 r/- r/- 0

### 2.13.9 FMMU reserved (0x060D:0x060F)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
23:0 Reserved, write 0 r/- r/- 0
```

II- 100 slave controller – register description

## 2.14 SyncManager

In the address range 0x0800:0x087F, 8 bytes are used per SyncManager y (0x0800+y*8:
0x0807+y*8). Throughout this chapter, the register addresses for SyncManager 0 are shown.

## Table 18: SyncManager register overview

```
Register address offset Length^
(byte)
```
```
Description
```
+0x0:0x1 (^2) Start address
+0x2:0x3 (^2) Length
+0x4 (^1) Control register
+0x5 (^1) Status register
+0x6 (^1) Activate
+0x7 (^1) PDI control

### 2.14.1 SyncManager start address (0x0800:0x0801)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
15:0 First byte that will be handled by
SyncManager
```
```
r/(w) r/- 0
```
NOTE r/(w): Register can only be written if SyncManager is disabled (+0x6[0] = 0).

### 2.14.2 SyncManager length (0x0802:0x0803)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
15:0 Number of bytes assigned to SyncManager
(shall be greater than 1, otherwise
SyncManager is not activated. If set to 1, only
Watchdog trigger is generated if configured)
```
```
r/(w) r/- 0
```
NOTE r/(w): Register can only be written if SyncManager is disabled (+0x6[0] = 0).


```
slave controller – register description II- 101
```
### 2.14.3 SyncManager control (0x0804)

```
ESC20 ET1100 ET1150 ET1200 IP core
[7] [7] [7] [7]
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
1:0 (^) Operation mode:
00: Buffered (3 buffer mode)
01: Reserved
10: Mailbox (single buffer mode)
11: Reserved
r/(w) r/-^00
3:2 (^) Direction:
00: Read: ECAT read access, PDI write
access.
01: Write: ECAT write access, PDI read
access.
10: Reserved
11: Reserved
r/(w) r/-^00
(^4) Interrupt in ECAT event request register:
0: Disabled
1: Enabled
r/(w) r/-^0
(^5) Interrupt in AL event request register:
0: Disabled
1: Enabled
r/(w) r/-^0
(^6) Watchdog trigger enable:
0: Disabled
1: Enabled
r/(w) r/-^0
(^7) Sequential mode:
0: Disabled
1: Enabled for ECAT write access (SM
must be written completely from start to
end address)
r/(w) r/-^0
NOTE r/(w): Register can only be written if SyncManager is disabled (+0x6[0] = 0).


II- 102 slave controller – register description

### 2.14.4 SyncManager status (0x0805)

```
ESC20 ET1100 ET1150 ET1200 IP core
[2, 7:6] [2, 7:6] [2, 7:6] [7:6]
V2.3.0/
V2.03a
[2]
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Interrupt write:
1: Interrupt after buffer was completely and
successfully written
0: Interrupt cleared after first byte of buffer
was read
NOTE: This interrupt is signalled to the reading
side if enabled in the SM control register.
r/- r/-^0
(^1) Interrupt read:
1: Interrupt after buffer was completely and
successfully read
0: Interrupt cleared after first byte of buffer
was written
NOTE: This interrupt is signalled to the writing
side if enabled in the SM control register.
r/- r/-^0
(^2) Sequential mode violation:
0: No violation/disabled
1: Violated. ECAT closed last write buffer
without writing completely from start to
end address
r/- r/-^0
(^3) Mailbox mode: mailbox status:
0: Mailbox empty
1: Mailbox full
Buffered mode: reserved
r/- r/-^0
5:4 Buffered mode: buffer status (last written
buffer):
00: 1 st buffer
01: 2 nd buffer
10: 3 rd buffer
11: (no buffer written)
Mailbox mode: reserved
r/- r/-^11
(^6) Read buffer in use (opened) r/- r/- 0
(^7) Write buffer in use (opened) r/- r/- 0
NOTE: When SyncManager deactivation delay is active (0x0807+8*y[7]=1) and SyncManager sequential mode is
disabled (0x0804+8*y[7]=0), reading register bits [6:3] from ECAT will not show the actual values, but the reset
values (for compatibility reasons). Reading these register bits from PDI will show the actual values.


```
slave controller – register description II- 103
```
### 2.14.5 SyncManager activate (0x0806)

```
ESC20 ET1100 ET1150 ET1200 IP core
[7:6]
(w ack)
(w ack)
```
```
[7:6]
(w ack)
Bit Description ECAT^ PDI^ Reset value^
```
(^0) SyncManager enable/disable:
0: Disable: access to memory without
SyncManager control
1: Enable: SyncManager is active and
controls memory area set in
configuration
r/w r/^
(w ack)*
0
(^1) Repeat request:
A toggle of repeat request means that a
mailbox retry is needed (primarily used in
conjunction with ECAT read Mailbox)
r/w r/-^0
5:2 (^) Reserved, write 0 r/- r/- 0
(^6) Latch event ECAT:
0: No
1: Generate latch event when EtherCAT
master issues a buffer exchange
r/w r/-^0
(^7) Latch event PDI:
0: No
1: Generate latch events when PDI issues
a buffer exchange or when PDI
accesses buffer start address
r/w r/-^0
* PDI register function acknowledge by write command is disabled: reading this register from PDI in all
SyncManagers which have changed activation clears AL event request 0x0220[4]. Writing to this register from
PDI is not possible. Default if feature is not available.
PDI register function acknowledge by write command is enabled: Writing register 0x0806 (SyncManager 0 only)
from PDI clears AL event request 0x0220[4] for all SyncManagers. Writing to register 0x0806 (not 0x080E+y*8)
from PDI is possible; write value is ignored (write 0).


II- 104 slave controller – register description

### 2.14.6 SyncManager PDI control (0x0807)

```
ESC20 ET1100 ET1150 ET1200 IP core
[7:6] [7:6] [7:6] [7:6]
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Deactivate SyncManager:
Read:
0: Normal operation, SyncManager
activated.
1: SyncManager deactivated and reset.
SyncManager locks access to type
area.
Write:
0: Activate SyncManager
1: Request SyncManager deactivation
NOTE: Writing 1 is delayed until the end of the
frame, which is currently processed.
r/- r/w^0
(^1) Repeat acknowledge:
If this is set to the same value as that set by
repeat request, the PDI acknowledges the
execution of a previous set repeat request.
r/- r/w^0
5 :2 (^) Reserved, write 0 r/- r/- 0
(^6) SyncManager deactivation delay:
0: Disabled. SyncManager deactivated
immediately after 0x0806+8*y[0]=0
1: Enabled. PDI can finish reading even
after 0x0806+8*y[0]=0
NOTE: EEPROM value is only taken over at first
EEPROM load after power-on or reset
r/- r/w^ IP core: depends^ on
configuration
ET1150: 0, later
EEPROM word A5[3]
Others: 0
(^7) SyncManager deactivation delay status:
0: Normal operation
1: SyncManager disabled by master, but
PDI may still read last buffer. Buffer
protection is still active.
NOTE: This register is 0 if SyncManager
deactivation delay is disabled in bit [6].
r/- r/-^0


```
slave controller – register description II- 105
```
## 2.15 Distributed clocks

### 2.15.1 Receive times

**2.15.1.1 Receive time port 0 (0x0900:0x0903)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
7 :0 (^) Write:
A write access to register 0x0900 with
BWR or FPWR latches the local time at
the beginning of the receive frame (start
first bit of preamble) at each port.
Write (ESC20, ET1200 exception):
A write access latches the local time at
the beginning of the receive frame at
port 0. It enables the time stamping at
the other ports.
Read:
Local time at the beginning of the last
receive frame containing a write access
to this register.
NOTE: FPWR requires an address match for
accessing this register like any FPWR command.
All write commands with address match will
increment the working counter (e.g., APWR), but
they will not trigger receive time latching.
r/w
(special
function)
r/- Undefined
31:8 (^) Local time at the beginning of the last receive
frame containing a write access to register
0x0900.
r/- r/-^ Undefined^
NOTE: The time stamps cannot be read in the same frame in which this register was written.
**2.15.1.2 Receive time port 1 (0x0904:0x0907)
ESC20 ET1100 ET1150 ET1200** IP core
**Bit Description ECAT**^ **PDI**^ **Reset value**^
31:0 (^) Local time at the beginning of a frame (start
first bit of preamble) received at port 1
containing a BWR or FPWR to register
0x0900.
ESC20, ET1200 exception:
Local time at the beginning of the first frame
received at port 1 after time stamping was
enabled. Time stamping is disabled for this
port afterwards.
r/- r/-^ Undefined
**2.15.1.3 Receive time port 2 (0x0908:0x090B)**
ESC20 **ET1100 ET1150** ET1200 IP core
**Bit Description ECAT**^ **PDI**^ **Reset value**^
31:0 (^) Local time at the beginning of a frame (start
first bit of preamble) received at port 2
containing a BWR or FPWR to register
0x0900.
r/- r/-^ Undefined^


II- 106 slave controller – register description

**2.15.1.4 Receive time port 3 (0x090C:0x090F)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
31:0 (^) Local time at the beginning of a frame (start
first bit of preamble) received at port 3
containing a BWR or FPWR to register
0x0900.
ET1200 exception:
Local time at the beginning of the first frame
received at port 3 after time stamping was
enabled. Time stamping is disabled for this
port afterwards.
r/- r/-^ Undefined^
**NOTE: System time (0x0910:0x0917) is described in chapter 2.15.2.1
2.15.1.5 Receive time ECAT processing unit (0x0918:0x091F)
ESC20** ET1100 ET1150 **ET1200** IP core
[63:32] [63:32]
optional
**Bit Description ECAT**^ **PDI**^ **Reset value**^
63:0 (^) Local time at the beginning of a frame (start
first bit of preamble) received at the ECAT
processing unit containing a write access to
register 0x0900
NOTE: E.g., if port 0 is open, this register reflects
the receive time port 0 as a 64 bit value.
Any valid EtherCAT write access to register
0x0900 triggers latching, not only BWR/FPWR
commands as with register 0x0900.
r/- r/-^ Undefined^


```
slave controller – register description II- 107
```
### 2.15.2 Time loop control unit

Time loop control unit is usually assigned to ECAT. Write access to time loop control registers by PDI
instead of ECAT is only possible with explicit ESC configuration.

**2.15.2.1 System time (0x0910:0x0917)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[63:32] [63:32]
optional
Bit Description ECAT^ PDI^ Reset value^
63:0 ECAT read access: local copy of the system
time when the frame passed the reference
clock (i.e., including system time delay).
Time latched at beginning of the frame
(Ethernet SOF delimiter)
```
```
r -^0
```
```
63:0 PDI read access: local copy of the system
time. Time latched when reading first byte
(0x0910)
```
- r^

```
31:0 ECAT write access: Written value will be
compared with the local copy of the system
time. The result is an input to the time control
loop.
```
```
NOTE: written value will be compared at the end
of the frame with the latched (SOF) local copy of
the system time if at least the first byte (0x0910)
was written.
```
```
(w)
(special
function)
```
##### -

```
31:0 PDI write access: Written value will be
compared with LATCH0 time positive edge
time. The result is an input to the time control
loop.
```
```
NOTE: written value will be compared at the end
of the access with LATCH0 time positive edge
(0x09B0:0x09B3) if at least the last byte (0x0913)
was written.
```
- (w)^
    (special
    function)

NOTE: Write access to this register depends upon ESC configuration (system time PDI-controlled off=ECAT/
on=PDI; ECAT control is common).

```
NOTE: Receive time ECAT processing unit (0x0918:0x091F) is described in the chapter 2.15.1.5
```

II- 108 slave controller – register description

**2.15.2.2 System time offset (0x0920:0x0927)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[63:32] [63:32]
optional
Bit Description ECAT^ PDI^ Reset value^
63:0 Difference between local time and system
time. Offset is added to the local time.
```
```
r/(w) r/(w) 0
```
NOTE: Write access to this register depends upon ESC configuration (system time PDI-controlled off=ECAT/
on=PDI; ECAT control is common). Reset internal system time difference filter and speed counter filter by writing
speed counter start (0x0930:0x0931) after changing this value.

**2.15.2.3 System time delay (0x0928:0x092B)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
31:0 Delay between reference clock and the ESC r/(w) r/(w) 0
```
NOTE: Write access to this register depends upon ESC configuration (system time PDI-controlled off=ECAT/
on=PDI; ECAT control is common). Reset internal system time difference filter and speed counter filter by writing
speed counter start (0x0930:0x0931) after changing this value.

**2.15.2.4 System time difference (0x092C:0x092F)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
30:0
Mean difference between local copy of
system time and received system time values
Difference = Received system time –
local copy of system time
```
```
r/- r/-^0
```
##### 31

```
0: Local copy of system time less than
received system time
1: Local copy of system time greater than
or equal to received system time
```
```
r/- r/-^0
```
NOTE: Register bits [31:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value.

**2.15.2.5 Speed counter start (0x0930:0x931)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
14:0 Bandwidth for adjustment of local copy of
system time (larger values → smaller
bandwidth and smoother adjustment)
A write access resets system time difference
(0x092C:0x092F) and speed counter diff
(0x0932:0x0933).
Valid values: 0x0080 to 0x3FFF
```
```
r/(w) r/(w) 0x1000^
```
```
15 Reserved, write 0 r/- r/- 0
```
NOTE: Write access to this register depends upon ESC configuration (system time PDI-controlled off=ECAT/
on=PDI; ECAT control is common).


```
slave controller – register description II- 109
```
**2.15.2.6 Speed counter diff (0x0932:0x933)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
15:0 Representation of the deviation between
local clock period and reference clock’s clock
period (representation: two’s complement)
Range: ±(speed counter start – 0x7F)
```
```
r/- r/- 0x0000^
```
NOTE: Calculate the clock deviation after system time difference has settled at a low value as follows:

𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷=

```
𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆
5 (𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆+𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆+2)(𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆−𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆𝑆+2)^
```
```
𝐿𝐿𝐷𝐷 𝐿𝐿𝐷𝐷 𝐿𝐿 𝐿𝐿𝐿𝐿𝐷𝐷𝐿𝐿 𝑐𝑐 𝑝𝑝𝐷𝐷 𝑝𝑝𝐷𝐷𝐷𝐷𝑝𝑝=(1−𝑝𝑝𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷𝐷)∗𝑝𝑝𝐷𝐷𝑟𝑟 𝐷𝐷𝑝𝑝𝐷𝐷𝐷𝐷𝐿𝐿𝐷𝐷 𝐿𝐿𝐿𝐿𝐷𝐷𝐿𝐿 𝑐𝑐 𝑝𝑝𝐷𝐷𝑝𝑝𝐷𝐷𝐷𝐷𝑝𝑝
```
**2.15.2.7 System time difference filter depth (0x0934)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
3:0 Filter depth for averaging the received
system time deviation
IP core since V2.2.0/V2.02a, ET1150:
A write access resets system time difference
(0x092C:0x092F)
```
```
r/(w) r/(w)^4
```
7:4 Reserved, write 0 (^) r/- r/- 0
NOTE: Write access to this register depends upon ESC configuration (system time PDI-controlled off=ECAT/
on=PDI; ECAT control is common).
ET1100, ET1200, ESC20, IP core before V2.2.0/V2.02a: reset system time difference by writing speed counter
start (0x0930:0x0931) after changing this value.
**2.15.2.8 Speed counter filter depth (0x0935)
ESC20** ET1100 ET1150 **ET1200** IP core
**Bit Description ECAT**^ **PDI**^ **Reset value**^
3:0 Filter depth for averaging the clock period
deviation
IP core since V2.2.0/V2.02a, ET1150:
A write access resets the internal speed
counter filter.
r/(w) r/(w)^12
7:4 Reserved, write 0 (^) r/- r/- 0
NOTE: Write access to this register depends upon ESC configuration (system time PDI-controlled off=ECAT/
on=PDI; ECAT control is common).
ET1100, ET1200, ESC20, IP core before V2.2.0/V2.02a: reset internal speed counter filter by writing speed
counter start (0x0930:0x0931) after changing this value.


II- 110 slave controller – register description

**2.15.2.9 Receive time latch mode (0x0936)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
0 Receive time latch mode:
0: Processing direction (used if frames are
entering the ESC at port 0 first):
receive time stamps of ports 1-3 are
enabled after the write access to
0x0900, so the following frame at ports
1-3 will be time stamped (this is typically
the write frame to 0x0900 coming back
from the network behind the ESC).
1: Forwarding direction (used if frames are
entering ESC at port 1-3 first):
receive time stamps of ports 1-3 are
immediately taken over from the internal
hidden time stamp registers, so the
previous frame entering the ESC at
ports 1-3 will be time stamped when the
write frame to 0x0900 enters port 0 (the
previous frame at ports 1-3 is typically
the write frame to 0x0900 coming from
the master, which will enable time
stamping at the ESC once it enters port
0).
```
```
r/w r/- 0
```
7:1 Reserved (^) r/- r/- 0
NOTE: There should not be frames traveling around the network before and after the time stamps are taken,
otherwise these frames might get time-stamped and not the write frame to 0x0900.
**2.15.2.10 Speed counter diff direct control (0x0938:0x0939)**
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
**Bit Description ECAT**^ **PDI**^ **Reset value**^
15:0 Speed counter diff direct control value. Valid
range: ±(speed counter start – 0x7F)
0: Direct control disabled
Other: Use value
r/(w) r/(w) 0
NOTE: Write access to this register depends upon ESC configuration (system time PDI-controlled off=ECAT/
on=PDI; ECAT control is common). Valid range is 0xF07F to 0x0F81 for default speed counter start value 0x1000;
written value is automatically reduced to fit into valid range.


```
slave controller – register description II- 111
```
### 2.15.3 Cyclic unit control

**2.15.3.1 SYNC2 cycle time (0x0940:0x0943)**

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
31:0 (^) Time between SYNC0 pulse and SYNC2
pulse in ns
r/(w) r/(w)^0
NOTE: Write to this register depends upon setting of 0x0980[2].
**2.15.3.2 SYNC3 cycle time (0x0944:0x0947)**
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
**Bit Description ECAT**^ **PDI**^ **Reset value**^
31:0 (^) Time between SYNC0 pulse and SYNC3
pulse in ns
r/(w) r/(w)^0
NOTE: Write to this register depends upon setting of 0x0980[3].
**2.15.3.3 Next SYNC2 pulse (0x0950:0x0957)**
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
**Bit Description ECAT**^ **PDI**^ **Reset value**^
63:0 System time of next SYNC2 pulse in ns r/- r/- 0
NOTE: Register bits [63:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value.
**2.15.3.4 Next SYNC3 pulse (0x0958:0x095F)**
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
**Bit Description ECAT**^ **PDI**^ **Reset value**^
63:0 System time of next SYNC3 pulse in ns r/- r/- 0
NOTE: Register bits [63:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value.


II- 112 slave controller – register description

**2.15.3.5 Cyclic unit control (0x0980)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[3:1, 7:6] [3:1, 7:6] [3:1, 7:6] [1]
V4.0.0
[3:2, 7:6]
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Cyclic unit and SYNC0 unit control:
0: ECAT-controlled
1: PDI-controlled
r/w r/-^0
(^1) SYNC1 unit control:
0: same as SYNC0
1: opposite to SYNC0
r/w r/-^0
(^2) SYNC2 unit control:
0: same as SYNC0
1: opposite to SYNC0
r/w r/-^0
(^3) SYNC3 unit control:
0: same as SYNC0
1: opposite to SYNC0
r/w r/-^0
(^4) Latch unit 0:
0: ECAT-controlled
1: PDI-controlled
NOTE: Latch interrupt is routed to ECAT/PDI
depending on this setting.
Always 1 (PDI-controlled) if system time is PDI-
controlled.
r/w r/-^0
(^5) Latch unit 1:
0: ECAT-controlled
1: PDI-controlled
NOTE: Latch interrupt is routed to ECAT/PDI
depending on this setting
r/w r/-^0
(^6) Latch unit 2:
0: ECAT-controlled
1: PDI-controlled
NOTE: Latch interrupt is routed to ECAT/PDI
depending on this setting
r/w r/-^0
(^7) Latch unit 3:
0: ECAT-controlled
1: PDI-controlled
NOTE: Latch interrupt is routed to ECAT/PDI
depending on this setting
r/w r/-^0


```
slave controller – register description II- 113
```
### 2.15.4 Sync unit

**2.15.4.1 Activation register (0x0981)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[7:3] [7:3] [7:3] [7:3]
V2.2.0/
V2.02a
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Cyclic unit activation:
0: Deactivated
1: Activated
r/(w) r/(w)^0
(^1) SYNC0 generation:
0: Deactivated
1: SYNC0 pulse is generated
r/(w) r/(w)^0
(^2) SYNC1 generation:
0: Deactivated
1: SYNC1 pulse is generated
r/(w) r/(w)^0
(^3) Auto-activation by writing start time cyclic
operation (0x0990:0x0997):
0: Disabled
1: Auto-activation enabled. 0x0981[0] is
set automatically after start time is
written.
r/(w) r/(w)^0
(^4) Extension of start time cyclic operation
(0x0990:0x0993):
0: No extension
1: Extend 32 bit written start time to 64 bit
r/(w) r/(w)^0
(^5) Start time plausibility check:
0: Disabled. SyncSignal generation if start
time is reached.
1: Immediate SyncSignal generation if
start time is outside near future (see
0x0981[6])
r/(w) r/(w)^0
(^6) Near future configuration (approx.):
0: ½ DC width future (2^31 ns or 2^63 ns)
1 : ~2.1 sec. future (2^31 ns)
r/(w) r/(w)^0
(^7) SyncSignal debug pulse (Vasily bit):
0: Deactivated
1: Immediately generate one ping only on
SYNC0-3 according to 0x0981[2:1] and
0x0986[1:0] for debugging
This bit is self-clearing, always read 0.
All pulses are generated at the same time,
the cycle time is ignored. The configured
pulse length is used.
r/(w) r/(w)^0
NOTE: Write to this register depends upon setting of 0x0980[0], except for 0x0981[2], which depends on
0x0980[1].


II- 114 slave controller – register description

**2.15.4.2 Pulse length of SyncSignals (0x0982:0x983)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
15:0 Pulse length of SyncSignals (in units of 10ns)
0: Acknowledge mode: SyncSignal will be
cleared by reading SYNC[3:0] status
register
```
```
r/- r/-^ IP core: depends^ on
configuration
Others: 0, later
EEPROM word A 2
```
**2.15.4.3 Activation status (0x0984)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[2:0]
V2.2.0/
V2.02a
[4:3]
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
(^0) SYNC0 activation state:
0: First SYNC0 pulse is not pending
1: First SYNC0 pulse is pending
r/- r/-^0
(^1) SYNC1 activation state:
0: First SYNC1 pulse is not pending
1: First SYNC1 pulse is pending
r/- r/-^0
2 Start time cyclic operation (0x0990:0x0997)
plausibility check result when Sync unit was
activated:
0: Start time was within near future
1: Start time was out of near future
(0x0981[6])
r/- r/-^0
(^3) SYNC2 activation state:
0: First SYNC2 pulse is not pending
1: First SYNC2 pulse is pending
r/- r/-^0
(^4) SYNC3 activation state:
0: First SYNC3 pulse is not pending
1: First SYNC3 pulse is pending
r/- r/-^0
7:5 Reserved r/- r/- 0


```
slave controller – register description II- 115
```
**2.15.4.4 Activation SYNC2/3 register (0x0986)**

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
(^0) SYNC2 generation:
0: Deactivated
1: SYNC2 pulse is generated
r/(w) r/(w)^0
(^1) SYNC3 generation:
0: Deactivated
1: SYNC3 pulse is generated
r/(w) r/(w)^0
7:2 (^) Reserved r/(w) r/(w) 0
NOTE: Write to 0x0986[0] depends upon setting of 0x0980[2], write to 0x0986[1] depends upon setting of
0x0980[3].


II- 116 slave controller – register description

**2.15.4.5 SYNC2 status (0x098C)**

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
0 SYNC2 state for acknowledge mode.
SYNC2 in acknowledge mode is cleared by
reading this register from PDI, use only in
acknowledge mode
```
```
r/- r/
(w ack)*
```
```
0
```
```
7:1 Reserved r/- r/
(w ack)*
```
```
0
```
* PDI register function acknowledge by write command is disabled: reading this register from PDI clears AL event
request 0x0220[24]. Writing to this register from PDI is not possible. Default if feature is not available.
PDI register function acknowledge by write command is enabled: Writing this register from PDI clears AL event
request 0x0220[24]. Writing to this register from PDI is possible; write value is ignored (write 0).

**2.15.4.6 SYNC3 status (0x098D)**

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
0 SYNC3 state for acknowledge mode.
SYNC3 in acknowledge mode is cleared by
reading this register from PDI, use only in
acknowledge mode
```
```
r/- r/
(w ack)*
```
```
0
```
```
7:1 Reserved r/- r/
(w ack)*
```
```
0
```
* PDI register function acknowledge by write command is disabled: reading this register from PDI clears AL event
request 0x0220[25]. Writing to this register from PDI is not possible. Default if feature is not available.
PDI register function acknowledge by write command is enabled: Writing this register from PDI clears AL event
request 0x0220[25]. Writing to this register from PDI is possible; write value is ignored (write 0).

**2.15.4.7 SYNC0 status (0x098E)**

```
ESC20 ET1100 ET1150 ET1200 IP core
(w ack) (w ack) (w ack)
Bit Description ECAT^ PDI^ Reset value^
0 SYNC0 state for acknowledge mode.
SYNC0 in acknowledge mode is cleared by
reading this register from PDI, use only in
acknowledge mode
```
```
r/- r/
(w ack)*
```
```
0
```
```
7:1 Reserved r/- r/
(w ack)*
```
```
0
```
* PDI register function acknowledge by write command is disabled: reading this register from PDI clears AL event
request 0x0220[2]. Writing to this register from PDI is not possible. Default if feature is not available.
PDI register function acknowledge by write command is enabled: Writing this register from PDI clears AL event
request 0x0220[2]. Writing to this register from PDI is possible; write value is ignored (write 0).


```
slave controller – register description II- 117
```
**2.15.4.8 SYNC1 status (0x098F)**

```
ESC20 ET1100 ET1150 ET1200 IP core
(w ack) (w ack) (w ack)
Bit Description ECAT^ PDI^ Reset value^
0 SYNC1 state for acknowledge mode.
SYNC1 in acknowledge mode is cleared by
reading this register from PDI, use only in
acknowledge mode
```
```
r/- r/
(w ack)*
```
```
0
```
```
7:1 Reserved r/- r/
(w ack)*
```
```
0
```
* PDI register function acknowledge by write command is disabled: reading this register from PDI clears AL event
request 0x0220[3]. Writing to this register from PDI is not possible. Default if feature is not available.
PDI register function acknowledge by write command is enabled: Writing this register from PDI clears AL event
request 0x0220[3]. Writing to this register from PDI is possible; write value is ignored (write 0).

```
NOTE: SYNC2 status (0x098C) is described in chapter 2.15.4.5
```
```
NOTE: SYNC3 status (0x098D) is described in chapter 2.15.4.6
```

II- 118 slave controller – register description

**2.15.4.9 Start time cyclic operation (0x0990:0x0997)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[63:32] [63:32]
optional
Bit Description ECAT^ PDI^ Reset value^
63:0 Write: start time (system time) of cyclic
operation in ns
Read: system time of next SYNC0 pulse in
ns
```
```
r/(w) r/(w) 0
```
NOTE: Register bits [63:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value.
Write to this register depends upon setting of 0x0980[0].

**Extension of start time (0x0981[4]=1):**
Upper 32 bits of start time cyclic operation (0x0994 to 0x0997) are automatically calculated after
writing the lower 32 bits only of start time cyclic operation (0x0990 to 0x0993), triggering extension
upon writing 0x0993. Upper 32 bits are calculated from current system time.
Extension of start time should either be used with auto-activation (0x0981[3]=1), or with an EtherCAT
datagram setting the activation register 0x0980[0]=1 in the same frame, otherwise the start time could
have expired before the DC Sync unit is activated.

**Explicit activation (0x0981[3]=0):**
Register value is used when 0x0981[0] has a transition to 1.

**Auto-activation (0x0981[3]=1):**
a) 32 bit distributed clocks or extension of start time used (0x0981[4]=1):
0x0981[0] is set automatically after lower 32 bits of start time cyclic operation (0x0990 to 0x0993) are
written, triggering activation upon writing 0x0993

b) 64 bit distributed clocks:
0x0981[0] is set automatically after all 64 bits of start time cyclic operation (0x0990 to 0x0997) are
written, triggering activation upon writing 0x0997

**2.15.4.10 Next SYNC1 pulse (0x0998:0x099F)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[63:32] [63:32]
optional
Bit Description ECAT^ PDI^ Reset value^
63:0 System time of next SYNC1 pulse in ns r/- r/- 0
```
NOTE: Register bits [63:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value.


```
slave controller – register description II- 119
```
**2.15.4.11 SYNC0 cycle time (0x09A0:0x09A3)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
31:0 Time between two consecutive SYNC0
pulses in ns.
0: Single shot mode, generate only one
SYNC0 pulse.
```
```
r/(w) r/(w)^0
```
NOTE: Write to this register depends upon setting of 0x0980[0]. Minimum value for cyclic operation: 60 [ns].

**2.15.4.12 SYNC1 cycle time (0x09A4:0x09A7)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
31:0 Time between SYNC0 pulse and SYNC1
pulse in ns
```
```
r/(w) r/(w) 0
```
NOTE: Write to this register depends upon setting of 0x0980[1:0].

```
NOTE: SYNC2 cycle time (0x0940:0x0943) is described in chapter 2.15.3.1
```
```
NOTE: SYNC3 cycle time (0x0944:0x0947) is described in chapter 2.15.3.2
```
```
NOTE: Next SYNC2 pulse (0x0950:0x0957) is described in chapter 2.15.3.3
```
```
NOTE: Next SYNC3 pulse (0x0958:0x095F) is described in chapter 2.15.3.4
```

II- 120 slave controller – register description

### 2.15.5 Latch unit

**2.15.5.1 LATCH0 control (0x09A8)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
(^0) LATCH0 positive edge:
0: Continuous latch active
1: Single event (only first event active)
r/(w) r/(w)^0
(^1) LATCH0 negative edge:
0: Continuous latch active
1: Single event (only first event active)
r/(w) r/(w)^0
7:2 (^) Reserved, write 0 r/- r/- 0
NOTE: Write access depends upon setting of 0x0980[4].
**2.15.5.2 LATCH1 control (0x09A9)
ESC20** ET1100 ET1150 **ET1200** IP core
**Bit Description ECAT**^ **PDI**^ **Reset value**^
(^0) LATCH1 positive edge:
0: Continuous latch active
1: Single event (only first event active)
r/(w) r/(w)^0
(^1) LATCH1 negative edge:
0: Continuous latch active
1: Single event (only first event active)
r/(w) r/(w)^0
7:2 Reserved, write 0 r/- r/- 0
NOTE: Write access depends upon setting of 0x0980[5].
**2.15.5.3 LATCH2 control (0x09AA)**
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
**Bit Description ECAT**^ **PDI**^ **Reset value**^
(^0) LATCH2 positive edge:
0: Continuous latch active
1: Single event (only first event active)
r/(w) r/(w)^0
(^1) LATCH2 negative edge:
0: Continuous latch active
1: Single event (only first event active)
r/(w) r/(w)^0
7:2 (^) Reserved, write 0 r/- r/- 0
NOTE: Write access depends upon setting of 0x0980[6].
**2.15.5.4 LATCH3 control (0x09AB)
ESC20 ET1100** ET1150 ET1200 IP core
V4.0.0
**Bit Description ECAT**^ **PDI**^ **Reset value**^
(^0) LATCH3 positive edge:
0: Continuous latch active
1: Single event (only first event active)
r/(w) r/(w)^0
(^1) LATCH3 negative edge:
0: Continuous latch active
1: Single event (only first event active)
r/(w) r/(w)^0
7:2 (^) Reserved, write 0 r/- r/- 0
NOTE: Write access depends upon setting of 0x0980[7].


```
slave controller – register description II- 121
```
**2.15.5.5 LATCH2 status (0x09AC)**

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Event LATCH2 positive edge.
0: Positive edge not detected or
continuous mode
1: Positive edge detected in single event
mode only.
Flag cleared by reading out LATCH2 time
positive edge.
r/- r/- 0
(^1) Event LATCH2 negative edge.
0: Negative edge not detected or
continuous mode
1: Negative edge detected in single event
mode only.
Flag cleared by reading out LATCH2 time
negative edge.
r/- r/- 0
2 LATCH2 pin state r/- r/- 0
7:3 Reserved r/- r/- 0
**2.15.5.6 LATCH3 status (0x09AD)**
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
**Bit Description ECAT**^ **PDI**^ **Reset value**^
(^0) Event LATCH3 positive edge.
0: Positive edge not detected or
continuous mode
1: Positive edge detected in single event
mode only.
Flag cleared by reading out LATCH3 time
positive edge.
r/- r/- 0
(^1) Event LATCH3 negative edge.
0: Negative edge not detected or
continuous mode
1: Negative edge detected in single event
mode only.
Flag cleared by reading out LATCH3 time
negative edge.
r/- r/- 0
2 LATCH3 pin state r/- r/- 0
7:3 Reserved r/- r/- 0


II- 122 slave controller – register description

**2.15.5.7 LATCH0 status (0x09AE)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[2] [2]
Bit Description ECAT^ PDI^ Reset value^
```
(^0) Event LATCH0 positive edge.
0: Positive edge not detected or
continuous mode
1: Positive edge detected in single event
mode only.
Flag cleared by reading out LATCH0 time
positive edge.
r/- r/- 0
(^1) Event LATCH0 negative edge.
0: Negative edge not detected or
continuous mode
1: Negative edge detected in single event
mode only.
Flag cleared by reading out LATCH0 time
negative edge.
r/- r/- 0
2 LATCH0 pin state r/- r/- 0
7:3 Reserved r/- r/- 0
**2.15.5.8 LATCH1 status (0x09AF)
ESC20** ET1100 ET1150 **ET1200** IP core
[2] [2]
**Bit Description ECAT**^ **PDI**^ **Reset value**^
(^0) Event LATCH1 positive edge.
0: Positive edge not detected or
continuous mode
1: Positive edge detected in single event
mode only.
Flag cleared by reading out LATCH1 time
positive edge.
r/- r/- 0
(^1) Event LATCH1 negative edge.
0: Negative edge not detected or
continuous mode
1: Negative edge detected in single event
mode only.
Flag cleared by reading out LATCH1 time
negative edge.
r/- r/- 0
2 LATCH1 pin state r/- r/- 0
7:3 Reserved r/- r/- 0


```
slave controller – register description II- 123
```
**2.15.5.9 LATCH0 time positive edge (0x09B0:0x09B7)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[63:32]
(w ack)
(w ack)
(w ack)
```
```
[63:32]
optional
Bit Description ECAT^ PDI^ Reset value^
63:0 System time at the positive edge of the
LATCH0 signal.
```
```
r(ack)/- r/
(w ack)*
```
```
0
```
NOTE: Register bits [63:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value. Reading this register from ECAT clears LATCH0 status 0x09AE[0] if
0x0980[4]=0. Writing to this register from ECAT is not possible.

* PDI register function acknowledge by write command is disabled: reading this register from PDI if 0x0980[4]=1
clears LATCH0 status 0x09AE[0]. Writing to this register from PDI is not possible. Default if feature is not
available.
PDI register function acknowledge by write command is enabled: writing this register from PDI if 0x0980[4]=1
clears LATCH0 status 0x09AE[0]. Writing to this register from PDI is possible; write value is ignored (write 0).

**2.15.5.10 LATCH0 time negative edge (0x09B8:0x09BF)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[63:32]
(w ack)
(w ack)
(w ack)
```
```
[63:32]
optional
Bit Description ECAT^ PDI^ Reset value^
63:0 System time at the negative edge of the
LATCH0 signal.
```
```
r(ack)/- r/
(w ack)*
```
```
0
```
NOTE: Register bits [63:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value. Reading this register from ECAT clears LATCH0 status 0x09AE[1] if
0x0980[4]=0. Writing to this register from ECAT is not possible.

* PDI register function acknowledge by write command is disabled: reading this register from PDI if 0x0980[4]=1
clears LATCH0 status 0x09AE[1]. Writing to this register from PDI is not possible. Default if feature is not
available.
PDI register function acknowledge by write command is enabled: writing this register from PDI if 0x0980[4]=1
clears LATCH0 status 0x09AE[1]. Writing to this register from PDI is possible; write value is ignored (write 0).

**2.15.5.11 LATCH1 time positive edge (0x09C0:0x09C7)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[63:32]
(w ack)
(w ack)
(w ack)
```
```
[63:32]
optional
Bit Description ECAT^ PDI^ Reset value^
63:0 System time at the positive edge of the
LATCH1 signal.
```
```
r(ack)/- r/
(w ack)*
```
```
0
```
NOTE: Register bits [63:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value. Reading this register from ECAT clears LATCH1 status 0x09AF[0] if
0x0980[5]=0. Writing to this register from ECAT is not possible.

* PDI register function acknowledge by write command is disabled: reading this register from PDI if 0x0980[5]=1
clears LATCH1 status 0x09AF[0]. Writing to this register from PDI is not possible. Default if feature is not
available.
PDI register function acknowledge by write command is enabled: writing this register from PDI if 0x0980[5] =1
clears LATCH1 status 0x09AF[0]. Writing to this register from PDI is possible; write value is ignored (write 0).

**2.15.5.12 LATCH1 time negative edge (0x09C8:0x09CF)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[63:32]
(w ack)
(w ack)
(w ack)
```
```
[63:32]
optional
```

II- 124 slave controller – register description

```
Bit Description ECAT^ PDI^ Reset value^
63:0 System time at the negative edge of the
LATCH1 signal.
```
```
r(ack)/- r/
(w ack)*
```
```
0
```
NOTE: Register bits [63:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value. Reading this register from ECAT clears LATCH1 status 0x09AF[1] if
0x0980[5]=0. Writing to this register from ECAT is not possible.

* PDI register function acknowledge by write command is disabled: reading this register from PDI if 0x0980[5]=1
clears LATCH1 status 0x09AF[1]. Writing to this register from PDI is not possible. Default if feature is not
available.
PDI register function acknowledge by write command is enabled: writing this register from PDI if 0x0980[5]=1
clears LATCH1 status 0x09AF[1]. Writing to this register from PDI is possible; write value is ignored (write 0).

**2.15.5.13 LATCH2 time positive edge (0x09D0:0x09D7)**

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
[63:32]
optional
Bit Description ECAT^ PDI^ Reset value^
63:0 System time at the positive edge of the
LATCH2 signal.
```
```
r(ack)/- r/
(w ack)*
```
```
0
```
NOTE: Register bits [63:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value. Reading this register from ECAT clears LATCH2 status 0x09AC[0] if
0x0980[6]=0. Writing to this register from ECAT is not possible.

* PDI register function acknowledge by write command is disabled: reading this register from PDI if 0x0980[6]=1
clears LATCH2 status 0x09AC[0]. Writing to this register from PDI is not possible. Default if feature is not
available.
PDI register function acknowledge by write command is enabled: writing this register from PDI if 0x0980[6] =1
clears LATCH2 status 0x09AC[0]. Writing to this register from PDI is possible; write value is ignored (write 0).

**2.15.5.14 LATCH2 time negative edge (0x09D8:0x09DF)**

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
[63:32]
optional
Bit Description ECAT^ PDI^ Reset value^
63:0 System time at the negative edge of the
LATCH2 signal.
```
```
r(ack)/- r/
(w ack)*
```
```
0
```
NOTE: Register bits [63:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value. Reading this register from ECAT clears LATCH2 status 0x09AC[1] if
0x0980[6]=0. Writing to this register from ECAT is not possible.

* PDI register function acknowledge by write command is disabled: reading this register from PDI if 0x0980[6]=1
clears LATCH2 status 0x09AC[1]. Writing to this register from PDI is not possible. Default if feature is not
available.
PDI register function acknowledge by write command is enabled: writing this register from PDI if 0x0980[6]=1
clears LATCH2 status 0x09AC[1]. Writing to this register from PDI is possible; write value is ignored (write 0).


```
slave controller – register description II- 125
```
**2.15.5.15 LATCH3 time positive edge (0x09E0:0x09E7)**

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
[63:32]
optional
Bit Description ECAT^ PDI^ Reset value^
63:0 System time at the positive edge of the
LATCH3 signal.
```
```
r(ack)/- r/
(w ack)*
```
```
0
```
NOTE: Register bits [63:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value. Reading this register from ECAT clears LATCH3 status 0x09AD[0] if
0x0980[7]=0. Writing to this register from ECAT is not possible.

* PDI register function acknowledge by write command is disabled: reading this register from PDI if 0x0980[7]=1
clears LATCH3 status 0x09AD[0]. Writing to this register from PDI is not possible. Default if feature is not
available.
PDI register function acknowledge by write command is enabled: writing this register from PDI if 0x0980[7] =1
clears LATCH3 status 0x09AD[0]. Writing to this register from PDI is possible; write value is ignored (write 0).

**2.15.5.16 LATCH3 time negative edge (0x09E8:0x09EF)**

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
[63:32]
optional
Bit Description ECAT^ PDI^ Reset value^
63:0 System time at the negative edge of the
LATCH3 signal.
```
```
r(ack)/- r/
(w ack)*
```
```
0
```
NOTE: Register bits [63:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value. Reading this register from ECAT clears LATCH3 status 0x09AD[1] if
0x0980[7]=0. Writing to this register from ECAT is not possible.

* PDI register function acknowledge by write command is disabled: reading this register from PDI if 0x0980[7]=1
clears LATCH3 status 0x09AD[1]. Writing to this register from PDI is not possible. Default if feature is not
available.
PDI register function acknowledge by write command is enabled: writing this register from PDI if 0x0980[7] =1
clears LATCH3 status 0x09AD[1]. Writing to this register from PDI is possible; write value is ignored (write 0).


II- 126 slave controller – register description

### 2.15.6 SyncManager event times

**2.15.6.1 EtherCAT buffer change event time (0x09F0:0x09F3)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
31:0 Local time at the beginning of the frame
which causes at least one SyncManager to
assert an ECAT event
```
```
r/- r/- 0
```
NOTE: Register bits [31:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value.

**2.15.6.2 PDI buffer start event time (0x09F8:0x09FB)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
31:0 Local time when at least one SyncManager
asserts a PDI buffer start event
```
```
r/- r/- 0
```
NOTE: Register bits [31:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value.

**2.15.6.3 PDI buffer change event time (0x09FC:0x09FF)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
31:0 Local time when at least one SyncManager
asserts a PDI buffer change event
```
```
r/- r/- 0
```
NOTE: Register bits [31:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value.


```
slave controller – register description II- 127
```
## 2.16 ESC-specific registers

### 2.16.1 Power-on values

**2.16.1.1 Power-on values ET1200 (0x0E00)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
1:0 (^) Chip mode (MODE):
00: Port 0: EBUS, port 1: EBUS, 18 pin PDI
01: Reserved
10: Port 0: MII, port 1: EBUS, 8 pin PDI
11: Port 0: EBUS, port 1: MII, 8 pin PDI
r/- r/-^ Depends on hardware^
configuration
3:2 (^) CPU clock output (CLK_MODE):
00: Off – PDI[7] available as PDI port
01: PDI[7] = 25MHz
10: PDI[7] = 20MHz
11: PDI[7] = 10MHz
r/- r/-^
5:4 TX signal shift (C25_SHI):
00: MII TX signals shifted by 0°
01: MII TX signals shifted by 90°
10: MII TX signals shifted by 180°
11: MII TX signals shifted by 270°
r/- r/-
(^6) CLK25 output enable (C25_ENA):
0: Disabled – PDI[6] available as PDI port
1: Enabled – PDI[6] = 25MHz (OSC)
NOTE: Only used in chip mode 10 and 11
r/- r/-^
(^7) PHY address offset (PHYAD_OFF):
0: No PHY address offset
1: PHY address offset is 16
r/- r/-^


II- 128 slave controller – register description

**2.16.1.2 Power-on values ET1100 (0x0E00:0x0E01)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
1:0 (^) Port mode (P_MODE):
00: Logical ports 0 and 1 available
01: Logical ports 0, 1 and 2 available
10: Logical ports 0, 1 and 3 available
11: Logical ports 0, 1, 2 and 3 available
r/- r/-^ Depends on hardware^
configuration
5:2 Physical layer of available ports (P_CONF).
Bit 2 → logical port 0, bit 3 → logical port 1,
bit 4 → third logical port (2/3), bit 5 → logical
port 3.
0: EBUS
1: MII
r/- r/-
7:6 (^) CPU clock output (CLK_MODE):
00: Off – PDI[7] available as PDI port
01: PDI[7] = 25MHz
10: PDI[7] = 20MHz
11: PDI[7] = 10MHz
r/- r/-^
9:8 (^) TX signal shift (C25_SHI):
00: MII TX signals shifted by 0°
01: MII TX signals shifted by 90°
10: MII TX signals shifted by 180°
11: MII TX signals shifted by 270°
r/- r/-^
(^10) CLK25 output enable (C25_ENA):
0: Disabled – PDI[31] available as PDI port
1: Enabled – PDI[31] = 25MHz (OSC)
r/- r/-^
(^11) Transparent mode (TRANS_MODE_ENA):
0: Disabled
1: Enabled – ERR is input (0: TX signals
are tri -stated, 1: ESC is driving TX
signals)
r/- r/-^
(^12) Digital control/status move
(CTRL_STATUS_MOVE):
0: Control/status signals are mapped to
PDI[39:32] – if available
1: control/status signals are remapped to
the highest available PDI byte.
r/- r/-^
(^13) PHY address offset (PHYAD_OFF):
0: No PHY address offset
1: PHY address offset is 16
r/- r/-^
(^14) PHY link polarity (LINKPOL):
0: LINK_MII is active low
1: LINK_MII is active high
r/- r/-^
15 Reserved configuration bit r/- r/-


```
slave controller – register description II- 129
```
**2.16.1.3 Power-on values ET1150 (0x0E00:0x0E05)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
1:0 (^) Port mode (P_MODE):
00: Logical ports 0 and 1 available
01: Logical ports 0, 1 and 2 available
10: Logical ports 0, 1 and 3 available
11: Logical ports 0, 1, 2 and 3 available
r/- r/-^ Depends on
hardware
configuration
5:2 Physical layer of available ports (P_CONF).
Bit 2 → logical port 0, bit 3 → logical port 1, bit 4 → third
logical port (2/3), bit 5 → logical port 3.
0: EBUS
1: MII
r/- r/-
7:6 (^) CPU clock output (CLK_MODE):
00: Off – PDI[7] available as PDI port
01: PDI[7] = 25MHz
10: PDI[7] = 20MHz
11: PDI[7] = 10MHz
r/- r/-^
9:8 TX signal shift (C25_SHI):
00: MII TX signals shifted by 0°
01: MII TX signals shifted by 90°
10: MII TX signals shifted by 180°
11: MII TX signals shifted by 270°
r/- r/-
(^10) CLK25 output enable (C25_ENA):
0: Disabled – PDI[31] available as PDI port
1: Enabled – PDI[31] = 25MHz (OSC)
r/- r/-^
11 Transparent mode (TRANS_MODE_ENA):
0: Disabled
1: Enabled – ERR is input (0: TX signals are tri-
stated, 1: ESC is driving TX signals)
r/- r/-
(^12) Digital control/state move (CTRL_STATUS_MOVE):
0: Control/status signals are mapped to PDI[39:32] –
if available
1: Control/status signals are remapped to the highest
available PDI byte.
r/- r/-^
(^13) PHY address offset[4] (PHYAD_OFF[4]):
0: PHY address offset +0
1: PHY address offset +16
r/- r/-^
(^14) PHY link polarity (LINKPOL):
0: LINK_MII/LINK_RGMII is active low
1: LINK_MII/LINK_RGMII is active high
r/- r/-^
(^15) Reserved configuration bit r/- r/-
18:16 (^) EEPROM emulation configuration
(PROM_SIZE :PROM_DATA:PROM_CLK):

## 000: SPI (PDI type 0x05)

## 001: 8 bit async μC (PDI type 0x09)

## 010: 16 bit async μC (PDI type 0x08)

## 011: 8 bit sync μC (PDI type 0x0B)

## 100: 16 bit sync μC (PDI type 0x0A)

## 101: 8 bit mux async μC (PDI type 0x0D)

## 110: 16 bit mux async μC (PDI type 0x0C)

## 111: 32 bit mux async μC (PDI type 0x0D)

```
NOTE: EEPROM emulation configuration is 000 if
EEPROM emulation enable=0.
```
```
r/- r/-^
```

II- 130 slave controller – register description

```
Bit Description ECAT^ PDI^ Reset value^
```
(^19) EEPROM emulation enable:
0: Disabled
1: Enabled
r/- r/-^
23:20 (^) Power supply configuration VCC_CONF[1:0]:
0000: VCC I/O COM=3.3V, VCC I/O PDI=3.3V, LDO
0001: VCC I/O COM=2.5V, VCC I/O PDI=2.5V, LDO
0010: VCC I/O COM=3.3V, VCC I/O PDI=2.5V, LDO
0100: VCC I/O COM=3.3V, VCC I/O PDI=3.3V, DC/DC
0101: VCC I/O COM=2.5V, VCC I/O PDI=2.5V, DC/DC
0110: VCC I/O COM=3.3V, VCC I/O PDI=2.5V, DC/DC
1000: VCC I/O COM=3.3V, VCC I/O PDI=1.8V, LDO
1001: VCC I/O COM=2.5V, VCC I/O PDI=1.8V, LDO
1010: VCC I/O COM=1.8V, VCC I/O PDI=1.8V, LDO
other values: reserved
NOTE: [21:20]=00 if VCC_CONF0= GND
[21:20]=01 if VCC_CONF0= VCC_REG_IN
[21:20]=10 if VCC_CONF0= open
[23:22]=00 if VCC_CONF1 = GND
[23:22]=01 if VCC_CONF1 = VCC_REG_IN
[23:22]=10 if VCC_CONF1 = open
r/- r/-^
27:24 (^) RGMII physical port (x) if POR_ET1100=1, else 0:
0: MII
1: RGMII
r/- r/-^
31:28 (^) FX mode physical port (x) if POR_ET1100=1, else 0:
0: TX
1: FX
r/- r/-^


```
slave controller – register description II- 131
```
```
Bit Description ECAT^ PDI^ Reset value^
```
(^32) Extended POR values (POR_ET1100):
0: ET1100 compatible
1: additional POR values
r/- r/-^
(^33) PHY address offset[0] (PHYAD_OFF[0]):
0: PHY address offset +0
1: PHY address offset +1
r/- r/-^
(^34) PLL mode:
0: Standard (fixed phase)
1: Spread spectrum
r/- r/-^
(^35) OTP override status:
0: OTP did not change POR values
1: OTP changed POR values
r/- r/-^
(^36) OTP fab section CRC result:
0: CRC invalid
1: CRC valid
r/- r/-^
(^37) OTP feature section CRC result:
0: CRC invalid
1: CRC valid
r/- r/-^
(^38) OTP user section CRC result:
0: CRC invalid
1: CRC valid
r/- r/-^
(^39) OTP application section CRC result:
0: CRC invalid
1: CRC valid
r/- r/-^
47:4 (^0) Reserved r/- r/- 0


#### 2.16.3 OTP II- X slave controller – register description

### 2.16.2 ESC health

**2.16.2.1 ESC health status ET1150 (0x0E10:0x0E17)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
(^0) PDI pin sharing result:
0: PDI pin sharing ok
1: PDI pin sharing error
r/- r/-^ Depends on PDI
configuration
(^1) RAM BIST result:
0: RAM BIST ok
1: RAM BIST error
r/- r/-^ Depends on BIST result^
(^2) RAM BIST result override:
0: No override
1: Allow RAM access, although RAM is
disabled due to BIST RAM error
r/w r/w^0
(^3) VCC_REG undervoltage
0: normal function
1: undervoltage detected
Cleared by writing 0x0E10
r/- r/-^ undefined^
(^4) VCC_IO_COM undervoltage
0: normal function
1: undervoltage detected
Cleared by writing 0x0E10
r/- r/-^ undefined^
(^5) VCC_IO_PDI undervoltage
0: normal function
1: undervoltage detected
Cleared by writing 0x0E10
r/- r/-^ undefined^
(^6) VCC_PLL undervoltage (coarse)
0: normal function
1: undervoltage detected
Cleared by writing 0x0E10
r/- r/-^ undefined^
(^7) VCC_CORE undervoltage (coarse)
0: normal function
1: undervoltage detected
Cleared by writing 0x0E10
r/- r/-^1
(^8) VCC_PLL undervoltage (fine)
0: normal function
1: undervoltage detected
Cleared by writing 0x0E10
r/- r/-^ undefined^
(^9) VCC_CORE undervoltage (fine)
0: normal function
1: undervoltage detected
Cleared by writing 0x0E10
r/- r/-^ undefined^
(^10) Internal reset from ECAT/PDI detected
0: no reset detected
1: reset detected
Cleared by writing 0x0E10
r/- r/-^0
(^11) External reset detected
0: no reset detected
1: reset detected
Cleared by writing 0x0E10
r/- r/-^0
(^12) PLL coarse lock
0: normal function
1: coarse lock lost detected
Cleared by writing 0x0E10
r/- r/-^ undefined^


```
slave controller – register description II- 133
```
```
Bit Description ECAT^ PDI^ Reset value^
```
(^13) PLL fine lock
0: normal function
1: fine lock lost detected
Cleared by writing 0x0E10
r/- r/-^ undefined^
(^14) OTP write disabled after test modes:
0: normal function
1: OTP write disabled
Cleared by reset
r/- r/-^0
(^15) OTP initial load finished at POR sample:
0: finished
1: not finished, startup was delayed
r/- r/-^ Depends on OTP^
31:16 (^) Reserved, write 0 r/- r/- 0
55:32 (^) RAM BIST result:
Number of detected errors
r/- r/-^ Depends on BIST result^
58:56 (^) RAM BIST result:
Number of BIST runs with errors
r/- r/- Depends on BIST result
62:59 (^) Reserved, write 0 r/- r/- 0
(^63) PLL lock time
0: normal function
1: not locked within expected time
r/- r/-^ Depends on PLL^


II- 134 slave controller – register description

**2.16.2.2 ESC health status IP core (0x0E10:0x0E17)**

```
ESC20 ET1100 ET1150 ET1200 IP core
```
(^) evaluationV4.0.0^
**Bit Description ECAT**^ **PDI**^ **Reset value**^
3:0 (^) Reserved r/- r/- (^0)
(^4) Evaluation timeout:
0: no timeout
1: timeout counting down, expect restricted
function after some time
r/- r/-^0
(^5) ESC function restricted:
0: normal function
1: restricted function after evaluation
timeout
r/- r/-^0
63:6 (^) Reserved r/- r/- (^0)


```
slave controller – register description II- 135
```
##### 2.16.3 OTP

## Table 19: OTP Register Overview

```
Register Address Length^
(Byte)
```
```
Description
```
0x0E3 (^0 1) OTP ECAT Access State
0x0E31 (^1) OTP PDI Access State
0x0E32:0x0E3 (^3 2) OTP Control/Status
0x0E34:0x0E37 (^4) OTP Address
0x0E38:0x0E3B (^4) OTP Data
ECAT controls the OTP interface if OTP PDI Access register 0x0E31[0]=0, otherwise PDI controls the OTP
interface.
**2.16.3.1 OTP ECAT access state (0x0E30)**
ESC20 ET1100 **ET1150** ET1200 IP core
**Bit Description ECAT**^ **PDI**^ **Reset value**^
(^0) Access to OTP:
0: ECAT enables PDI takeover of OTP
1: ECAT claims exclusive access to OTP
r/(w) r/-^0
7:1 (^) Reserved, write 0 r/- r/- 0
NOTE: r/(w): write access is only possible if 0x0E31[0]=0.
**2.16.3.2 OTP PDI access state (0x0E31)**
ESC20 ET1100 **ET1150** ET1200 IP core
**Bit Description ECAT**^ **PDI**^ **Reset value**^
(^0) Access to OTP:
0: ECAT has access to OTP
1: PDI has access to OTP
r/- r/(w)^0
(^1) Force PDI access state:
0: Do not change bit 0x0E31[0]
1: Reset bit 0x0E31[0] to 0
r/w r/-^0
7:2 (^) Reserved, write 0 r/- r/- 0
NOTE: r/(w): assigning access to PDI (bit 0 = 1) is only possible if 0x0E30[0]=0 and 0x0E31[1]=0.


II- 136 slave controller – register description

**2.16.3.3 OTP control/status (0x0E32:0x0E33)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
(^0) OTP enable:
0: OTP disabled
1: OTP enabled
r/- r/-^0
(^1) OTP write enable:
0: Write disabled
1: Write enabled
r/- r/-^0
2 OTP access:
0: Normal access by ECAT/PDI
1: OTP access by JTAG only
r/- r/- 0
7:3 Reserved, write 0 (^) r/- r/- 0
10:8 (^) Command register*:^
Write: Initiate command.
Read: Currently executed command
Commands:
000: No command (clear error bits)
001: Read
010: Write and verify
100: Reload
011: Write enable
101: Write disable
110: Enable OTP
111: Disable OTP
r/(w) r/(w)^0
12: (^11) Write verification result:
00: Write success
01: Write success, additional bits had
already been set previously
10: Write error (not programmed)
11: Write error (weakly programmed)
Cleared by writing next command
r/- r/-^0
(^13) Write allowed:
0: Write allowed
1: Write not allowed (area protected)
Cleared by writing next command
r/- r/-^0
14 Command error:
0: Last command was successful
1: Command error
Cleared by writing next command
r/- r/- 0
(^15) Busy:
0: OTP interface is idle
1: OTP interface is busy
r/- r/-^0
NOTE: r/ (w): write access depends on assignment of OTP (ECAT/PDI). Write access is blocked if OTP is busy
(0x0E32[15]=1).
* Command bits [10:8] are self-clearing after the command is executed (Busy ends). Writing “000” to the
command register will also clear the error bits [14:13].


```
slave controller – register description II- 137
```
**2.16.3.4 OTP address (0x0E34:0x0E37)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
7:0 OTP byte address, must be 32 bit aligned
(i.e., 0x0E34[1:0]=00)
```
```
r/(w) r/(w)^ Undefined^
```
31:8 Reserved, write 0 (^) r/(w) r/(w)
NOTE: r/(w): write access depends on assignment of OTP (ECAT/PDI). Write access is blocked if OTP is busy
(0x0E32[15]=1).
**2.16.3.5 OTP data (0x0E38:0x0E3B)**
ESC20 ET1100 **ET1150** ET1200 IP core
**Bit Description ECAT**^ **PDI**^ **Reset value**^
31:0 OTP read/write data (^) r/(w) r/(w) Undefined
ET1150 only:
OTP BIST write status (read value after BIST write):
r/- r/-^
0 User space not empty
1 WL failure
2 Read failure test rows 0 to 4
5:3 Reserved
6 Disturb check read failure
7 Voltage pump failure
8 WL Booster voltage failure
9 Int ref word value failure
10 Ext ref word value failure
11 Test row value failure before programming
31:12 Reserved
NOTE: r/(w): write access depends on assignment of OPT (ECAT/PDI). Write access is blocked if OTP is busy
(0x0E32[15]=1).


II- 138 slave controller – register description

#### 2.16.4 Product and vendor ID

**2.16.4.1 Product ID (0x0E00:0x0E07)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
63:0 Product ID r/- r/- Depends on
configuration
```
**2.16.4.2 Vendor ID (0x0E08:0x0E0F)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
```
31:0 (^) Vendor ID:
[23:0] Company
[27:24] Department
[31:28] Reserved
NOTE: Test vendor IDs have [31:28]=0xE
r/- r/-^ Depends on License
file/signed Vendor ID
63:32 Reserved r/- r/-


```
slave controller – register description II- 139
```
#### 2.16.5 FPGA update

**2.16.5.1 FPGA update ESC20 (0x0E00:0x0EFF)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
--- FPGA update (ESC20 and TwinCAT only)
```

II- 140 slave controller – register description

### 2.17 ESC specific I/O

**2.17.1.1 Digital I/O output data (0x0F00:0x0F03)**

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
31:0 Output data r/w r/- 0
```
NOTE: Register size depends on PDI setting and/or device configuration. This register is bit-writable (using
Logical addressing).

**2.17.1.2 Digital I/O input data PDI1 (0x0F08:0x0F0B)**

```
ESC20 ET1100 ET1150 ET1200 IP core
V4.0.0
Bit Description ECAT^ PDI^ Reset value^
31:0 Input data PDI1 r/- r/- 0
```
NOTE: Register bits [31:8] are internally latched (ECAT/PDI independently) when bits [7:0] are read, which
guarantees reading a consistent value.

**2.17.1.3 General purpose output data (0x0F10:0x0F17)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[63:16] [63:12] optional
length
Bit Description ECAT^ PDI^ Reset value^
63:0 General purpose output data r/w r/w 0
ET1150 only:
Bidirectional operation for each pin individually:
31:0 Output data for PDI[31:0] depends on output
enable.
Output disabled:
0: Pin is high-impedance
1: Pin is pulled down
Output enabled:
0: Output is driven low
1: Output is driven high
```
```
r/w r/w 0
```
```
63:32 Output enable for PDI[31:0]
0: Output disable, pull-down configurable
1: Output enable, no pull-down
```
```
r/w r/w^0
```
NOTE: Usable general purpose outputs depends on PDI setting and/or device configuration

**2.17.1.4 General purpose input data (0x0F18:0x0F1F)**

```
ESC20 ET1100 ET1150 ET1200 IP core
[63:16] optional
length
Bit Description ECAT^ PDI^ Reset value^
63:0 General purpose^ input^ data^ r/-^ r/-^0
```
NOTE: Register size depends on PDI setting and/or device configuration


```
slave controller – register description II- 141
```
### 2.18 User RAM

#### 2.18.1 User RAM (0x0F80:0x0FFF)

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
---- Application-specific information r/w r/w IP core: extended^ ESC
features
Others:
Random/undefined
```
#### 2.18.2 ESC features (power-on values of user RAM)

```
ESC20 ET1100 ET1150 ET1200 IP core
V1.1.0/
V1.01a
Addr. Bit^ Feat. Description^ Reset value
IP core
```
(^)
**ESC features
0F80** 7:0 -^ Number of ESC feature bits Depends on ESC^
**FPGA IP:**
V1.1.0-V1.1.1,
V1.01a 31
V2.00,
V2.00a 35
V2.2.0-V2.2.1,
V2.02a 41
V2.3.0-V2.3.1,
V2.03a-V2.03d 49
V2.4.0,
V2.04a 51
V2.4.3-V2.4.4,
V2.04d-V2.04e 142
V3.0.0 149
V3.0.1-V3.0.10,
V3.00c-V3.00k 150
V4.0.0 244


II- 142 slave controller – register description

```
Addr. Bit^ Feat. Description^ Reset value
IP core
```
(^) ESC extended features:
Depends on ESC:
0: Not
available
1: Available
c: Configurable
**0F81** (^0 0) Extended DL control register (0x0102:0x0103) 1
(^1 1) AL status code register (0x0134:0x0135) c^
(^2 2) ECAT interrupt mask (0x0200:0x0201) 1
(^3 3) Configured station alias (0x0012:0x0013) 1
(^4 4) General purpose inputs (0x0F18:0x0F1F) c^
(^5 5) General purpose outputs (0x0F10:0x0F17) c^
(^6 6) AL event mask writable (0x0204:0x0207) c^
(^7 7) Physical read/write offset (0x0108:0x0109) c^
**0F82** (^0 8) Watchdog divider writable (0x0400:0x0401) and
Watchdog PDI (0x0410:0x0411)
c
(^1 9) Watchdog counters (0x0442:0x0443) c
(^2 10) Write protection (0x0020:0x0031) c
(^3 11) Reset (0x0040:0x0041) c
(^4 12) Reserved 0
(^5 13) DC SyncManager event times (0x09F0:0x09FF) c
(^6 14) ECAT processing unit/PDI error counter
(0x030C:0x030D)
1
(^7 15) EEPROM size configurable (0x0502[7]):
0: EEPROM size fixed to sizes up to 16 Kbit
1: EEPROM size configurable
1
**0F83** (^0 16) EEPROM control by PDI possible 1
(^1 17) Reserved 0
(^2 18) Reserved 0
(^3 19) Lost link counter (0x0310:0x0313) 1
(^4 20) PHY management interface (0x0510:0x0515) c^
(^5 21) Enhanced link detection MII c^
(^6 22) Enhanced link detection EBUS 0
(^7 23) Run LED c^
**0F84** (^0 24) Link/Activity LED 1
(^1 25) Reserved 0
(^2 26) Reserved 1
(^3 27) DC latch In unit c^
(^4 28) Reserved 0
(^5 29) DC Sync unit c^
(^6 30) DC time loop control assigned to PDI c^
(^7 31) Link detection and configuration by MI c^


```
slave controller – register description II- 143
```
**Addr. Bit**^ **Feat. Description**^ **Reset value
IP core**

**0F85** (^0 32) MI control by PDI possible 1
(^1 33) Automatic TX shift c
(^2 34) EEPROM emulation by μController c
(^3 35) Reserved 0
(^4 36) Reserved 0
(^5 37) Disable digital I/O register (0x0F00:0x0F03) c
(^6 38) Reserved 0
(^7 39) Reserved 0
**0F86** (^0 40) PDI user mode (0x0158, 0x015C) c
(^1 41) Extended RX error counter (0x0314:0x0317) c
(^2 42) RUN/ERR LED override (0x0138:0x0139) c
(^3 43) Reserved 0
(^4 44) Reserved 1
(^5 45) Reserved 0
(^6 46) Reserved 0
(^7 47) Reserved 0
**0F87** (^0 48) Reserved 0
(^1 49) Reserved 0
(^2 50) Reserved 0
(^3 51) DC SYNC1 disable c
(^4 52) Reserved 0
(^5 53) Reserved 0
(^6 54) DC receive times (0x0900:0x090F) c
(^7 55) DC system time (0x0910:0x0936) c
**0F88** (^0 56) DC 64 bit c
(^1 57) Reserved 0
(^2 58) PDI clears error counter 0
(^3 59) Avalon PDI c
(^4 60) OPB PDI 0
(^5 61) PLB PDI 0
(^6 62) Reserved 0
(^7 63) Reserved 0
**0F89** (^0 64) Reserved 0
(^1 65) Reserved 0
(^2 66) Reserved 0
(^3 67) Reserved 0
(^4 68) Reserved 0
(^5 69) Reserved 0
(^6 70) Reserved 0
(^7 71) Direct RESET 0


II- 144 slave controller – register description

```
Addr. Bit^ Feat. Description^ Reset value
IP core
```
**0F8A** (^0 72) Reserved 0
(^1 73) Reserved 1
(^2 74) DC LATCH1 disable c
(^3 75) AXI PDI c
(^4 76) Reserved 0
(^5 77) Reserved 0
(^6 78) PDI function acknowledge by PDI write c
(^7 79) PDI information register (0x014E:0x014F,
0x018E:0x018F)
1
**0F8B** (^0 80) Reserved 1
(^1 81) Reserved 1
(^2 82) Reserved 0
(^3 83) LED test c^
(^4 84) Reserved 0
(^5 85) Reserved 0
(^6 86) Reserved 0
(^7 87) Reserved 0
**0F8C** 3:0 91:88^ Reserved 0
7:4 95:92^ Reserved 0
**0F8D** 3:0 99:96^ Reserved 0
7:4 103:100^ Reserved 0
**0F8E** 3:0 107:104^ Reserved 0
(^4 108) Reserved 0
(^5 109) Reserved 0
7:6
112:110 Digital I/O PDI byte size c
**0F8F** 0
(^1 113) Reserved 0
(^2 114) Digital I/O PDI c^
(^3 115) SPI slave PDI c^
(^4 116) Asynchronous μC PDI c^
(^5 117) Reserved 0
(^6 118) Reserved 1
(^7 119) Reserved 1


```
slave controller – register description II- 145
```
**Addr. Bit**^ **Feat. Description**^ **Reset value
IP core**

**0F90** (^0 120) Reserved 0
(^1 121) PDI 1 c
(^2 122) Digital I/O input register (0x0F08:0x0F0B) c
(^3 123) Reserved c
(^4 124) Reserved 0
(^5 125) DC LATCH2 c
(^6 126) DC LATCH3 c
(^7 127) DC SYNC2 c
**0F91** (^0 128) DC SYNC3 c
(^1 129) Reserved 0
(^2 130) Reserved 0
(^3 131) Reserved 0
(^4 132) Reserved 0
(^5 133) Reserved 0
(^6 134) Reserved 0
(^7 135) Reserved 0
**0F92** (^0 136) Reserved 0
(^1 137) Reserved 0
(^2 138) Reserved 0
(^3 139) PDI watchdog status register (0x0448) 1
(^4 140) Reserved 1
(^5 141) Reserved 0
(^6 142) Reserved 0
(^7 143) Reserved 0
**0F93** (^0 144) RGMII 0
(^1 145) Individual PHY address read out (0x0510[7:3]) c
(^2 146) CLK_PDI_EXT is asynchronous c
(^3 147) CLK_PDI1_EXT is asynchronous c
(^4 148) Use RGMII GTX_CLK phase shifted clock input 1
(^5 149) RMII 0
(^6 150) Security CPLD protection 0
7
153:151 EEPROM I2C address offset c
**0F94** 1:0
5:2 157:154 Reserved 0
(^6 158) Reserved 0
(^7 159) Reserved 0


II- 146 slave controller – register description

```
Addr. Bit^ Feat. Description^ Reset value
IP core
0F95
0 160 Reserved 0
1 161 Reserved 0
4:2 164:162 Digital I/O PDI1 byte size c
5 165 Reserved 0
6 166 Reserved 0
7 167 Reserved 0
0F96 0 168 Digital I/O PDI1 c
1 169 SPI slave PDI1 c
2 170 Reserved 0
3 171 Reserved 0
4 172 Reserved 0
5 173 Reserved 0
6 174 Reserved 0
7 175 Reserved 0
0F97 0 176 Avalon PDI1 c
1 177 Reserved 0
2 178 Reserved 0
3 179 AXI PDI1 c
```
(^4 180) Reserved 0
(^5 181) Reserved 0
(^6 182) Reserved 0
(^7 183) Reserved 0
**0F98** 0 184 Reserved 0
1 185 PDI private RAM c
2 186 Reserved 0
3 187 PHY initialization user values c
4 188 Reserved 0
5 189 Reserved 0
7:6 191:190 Reserved 0


```
slave controller – register description II- 147
```
**Addr. Bit**^ **Feat. Description**^ **Reset value
IP core
0F99** 2:0 194:192 Reserved 0
3 195 Reserved 0
4 196 Reserved 0
5 197 Reserved 0
6 198 SyncManager deactivation delay 1
7 199 SyncManager sequential mode c

**0F9A** 0 200 Reserved c

```
1 201 Reserved 0
2 202 Reserved 0
3 203 ESC configuration area B supported c
4 204 Reserved 0
5 205 Reserved 0
6 206 Disable RAM initialization c
7 207 Reserved 0
```
**0F9B** 0 208 Reserved 0

```
1 209 Reserved 0
2 210 Reserved 0
3 211 Reserved 0
4 212 Reserved 0
5 213 Reserved 0
6 214 Reserved 0
7 219:215 Number of FMMUs c
```
**0F9C** 3:0

```
7:4
224:220
```
```
Number of SyncManagers c
```
**0F9D** 0

```
1 225 Reserved 0
2 226 Reserved 0
3 227 Enable additional SPI slave features PDI0 c
4 228 Enable additional SPI slave features PDI1 c
5 229 Reserved 0
6 230 Reserved 0
7 231 Reserved 0
```

II- 148 slave controller – register description

```
Addr. Bit^ Feat. Description^ Reset value
IP core
0F9E 0 232 Reserved 0
1 233 Use half I2C speed c
2 234 Reserved 0
3 235 Reserved 0
4 236 Reserved 0
5 237 Reserved 0
6 238 Reserved 0
7 239 Reserved 1
0F9F 0 240 Separate MI interface for each port c
1 241 Reserved 0
2 242 Reserved 0
3 243 Reserved 0
4 244 Reserved 0
5 245 Reserved 0
6 246 Reserved 0
7 247 Reserved 0
0FA0 0 248 Reserved 0
1 249 Reserved 0
2 250 Reserved 0
3 251 Reserved 0
4 252 Reserved 0
5 253 Reserved 0
6 254 Reserved 0
7 255 Reserved 0
0FDF:
0FA1
```
```
Reserved 0
```
NOTE: Reset values are for IP core V4.0.0


```
slave controller – register description II- 149
```
#### 2.18.3 ESC port features (power-on values of user RAM)

```
Addr. Bit^ Feat. Description^ Reset value
IP core
```
```
Port features for port 0-3 (64 bit each)
0FE0/
0FE8/
0FF0/
0FF8
```
(^0 0) Reserved 0
(^1 1) MII supported c
(^2 2) RMII supported c
(^3 3) RGMII supported c
(^4 4) Reserved 0
(^5 5) FX supported c
(^6 6) Reserved 0
(^7 7) Reserved 0
**0FE1/
0FE9/
0FF1/
0FF9**
(^0 8) EtherCAT 100 Mbps supported 1
(^1 9) Reserved 0
(^2 10) MI link detection and configuration supported c
(^3 11) Reserved 0
(^4 12) Enhanced link detection supported c
5 13 Reserved (^0)
6 14 Reserved (^0)
(^7 15) Reserved 0
**0FE2/
0FEA/
0FF2/
0FFA**
(^0 16) Reserved 0
(^1 17) Reserved 0
(^2 18) Reserved 0
(^3 19) Reserved 0
(^4 20) Reserved 0
(^5 21) Reserved 0
(^6 22) Reserved 0
(^7 23) Reserved 0
**0FE3/
0FEB/
0FF3/
0FFB**
(^0 24) Reserved 0
(^1 25) Reserved 0
(^2 26) Reserved 0
(^3 27) Reserved 0
(^4 28) Reserved 0
(^5 29) Reserved 0
(^6 30) Reserved 0
(^7 31) Reserved 0
**0FE4:
0FE7/
0FEC:
0FEF/
0FF4:
0FF7/
0FFC:
0FFF**
Reserved 0
NOTE: Reset values are for IP core V4.0.0


II- 150 slave controller – register description

### 2.19 Process data RAM

#### 2.19.1 Process data RAM (0x1000:0xFFFF)

The process data RAM starts at address 0x1000, its size depends on the ESC.

```
ESC20 ET1100 ET1150 ET1200 IP core
4 Kbyte 8 Kbyte 15 Kbyte 1 Kbyte size
configurable
Bit Description ECAT^ PDI^ Reset value^
Process data RAM (r/w) (r/w) Random/undefined
Private PDI process data RAM, size depends
on configuration
```
- /- r/w

NOTE: (r/w) Process data RAM is only accessible if EEPROM was correctly loaded (register 0x0110[0] = 1).

#### 2.19.2 Digital I/O input data PDI0 (0x1000:0x1003)

Digital I/O input data is written into the process data RAM by the digital I/O PDI0.

```
ESC20 ET1100 ET1150 ET1200 IP core
Bit Description ECAT^ PDI^ Reset value^
31:0 Input data (r/w) (r/w) Random/undefined
```
NOTE: (r/w) Process data RAM is only accessible if EEPROM was correctly loaded (register 0x0110[0] = 1).

NOTE: Input data size depends on PDI setting and/or device configuration. Digital I/O input data is written into the
process data RAM at these addresses if a digital I/O PDI with inputs is configured.


Appendix

```
slave controller – register description II- 151
```
## 3 Appendix

### 3.1 Support and service

Beckhoff and our partners around the world offer comprehensive support and service, making
available fast and competent assistance with all questions related to Beckhoff products and system
solutions.

#### 3.1.1 Beckhoff’s branch offices and representatives

Please contact your Beckhoff branch office or representative for local support and service on Beckhoff
products!

The addresses of Beckhoff's branch offices and representatives round the world can be found on her
internet pages: [http://www.beckhoff.com](http://www.beckhoff.com)

You will also find further documentation for Beckhoff components there.

### 3.2 Beckhoff headquarters

Beckhoff Automation GmbH & Co. KG
Huelshorstweg 20
33415 Verl
Germany

Phone: +49 (0) 5246 963- 0

Fax: +49 (0) 5246 963- 198

E-mail: info@beckhoff.com

Web: [http://www.beckhoff.com](http://www.beckhoff.com)

**Beckhoff support**

Support offers you comprehensive technical assistance, helping you not only with the application of
individual Beckhoff products, but also with other, wide-ranging services:

- world-wide support
- design, programming and commissioning of complex automation systems
- and extensive training program for Beckhoff system components

Hotline: +49 (0) 5246 963- 157

Fax: +49 (0) 5246 963- 9157

E-mail: support@beckhoff.com

**Beckhoff service**

The Beckhoff service center supports you in all matters of after-sales service:

- on-site service
- repair service
- spare parts service
- hotline service

Hotline: +49 (0) 5246 963- 460

Fax: +49 (0) 5246 963- 479

E-mail: service@beckhoff.com



