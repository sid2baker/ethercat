# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-03-07

### Added
- Pure-Elixir EtherCAT master runtime over standard Ethernet (raw socket + UDP transport)
- Declarative bus configuration via `EtherCAT.start/1` with `Slave.Config` and `Domain.Config`
- Cyclic process data exchange — self-timed LRW domain cycling with drift-compensated scheduling
- CoE SDO transfers (expedited and segmented) for mailbox-based slave configuration
- Distributed clocks support (`EtherCAT.DC.Config`) with automatic reference clock selection
- Subscribe-on-change signal API: `subscribe/2`, `read_input/2`, `write_output/3`
- `EtherCAT.Slave.Driver` behaviour for custom PDO encode/decode per device type
- Default auto-discovery driver for unknown slaves via SII EEPROM PDO scan
- `slave_info/1`, `domain_info/1`, `slaves/0`, `domains/0` introspection API
- Telemetry events for domain cycle done/missed
- Bus redundancy link support
