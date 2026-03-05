# EtherCAT Reference Index for Context Loading

This file is the primary entry point for reference loading.

Read this file first, then load only the chapter files required by the current task.

## Scope

These chapters summarize EtherCAT protocol behavior from the three local PDFs in `docs/references/`:
- `ethercat_system_description.pdf`
- `ethercat_esc_datasheet_sec1_technology_v2.5.pdf`
- `ethercat_esc_datasheet_sec2_registers_v3.3.pdf`

## Chapter Map

### Core Protocol and Framing
- [The EtherCAT Frame within the Ethernet Payload](./02-the-ethercat-frame-within-the-ethernet-payload.md)
- [The Four Pillars of Addressing](./03-the-four-pillars-of-addressing.md)
- [The Working Counter (WKC)](./04-the-working-counter-wkc.md)

### EtherCAT State Machine (ESM)
- [The ESM Architecture](./05-the-esm-architecture.md)
- [State Transitions and Validations](./06-state-transitions-and-validations.md)
- [AL Control and AL Status Registers](./07-al-control-and-al-status-registers.md)

### ESC Address Space and Identity
- [The 64 Kbyte Address Space](./08-the-64-kbyte-address-space.md)
- [The Core Control Registers](./09-the-core-control-registers.md)
- [The Slave Information Interface (SII) / EEPROM](./10-the-slave-information-interface-sii-eeprom.md)

### Data Path Configuration
- [SyncManagers (0x0800+)](./11-syncmanagers.md)
- [Fieldbus Memory Management Units (FMMU) (0x0600+)](./12-fieldbus-memory-management-units-fmmu.md)
- [Process Data Objects (PDO) Mapping](./13-process-data-objects-pdo-mapping.md)

### Distributed Clocks
- [Principles of DC Synchronization](./14-principles-of-dc-synchronization.md)
- [Topology and Propagation Delay Measurement](./15-topology-and-propagation-delay-measurement.md)
- [DC Registers and Compensation (0x0900+)](./16-dc-registers-and-compensation.md)

### Master Implementation Flow
- [Network Discovery and Initialization](./17-network-discovery-and-initialization.md)
- [The Configuration Sequence (Init to Pre-Op)](./18-the-configuration-sequence-init-to-pre-op.md)
- [Transitioning to Cyclic Operation (Pre-Op to Op)](./19-transitioning-to-cyclic-operation-pre-op-to-op.md)
- [The Continuous Loop](./20-the-continuous-loop.md)

### Remaining Application-Layer Work
- [The Missing Application Layers](./21-the-missing-application-layers.md)

## Selection Guidance

Choose files by feature area:
- Frame layout or datagrams: load framing + addressing + WKC chapters.
- State issues (Init/Pre-Op/Safe-Op/Op): load ESM + AL register chapters.
- PDO mapping or LRW data path: load SyncManager + FMMU + PDO chapters.
- Clocking and sync: load DC principle + delay + register chapters.
- Startup/runtime sequencing: load master implementation flow chapters.
- CoE/FoE/mailbox conformance gaps: load missing application layers chapter.
