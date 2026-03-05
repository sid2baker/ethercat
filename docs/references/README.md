# Reference Implementations

Two battle-tested EtherCAT master implementations cloned here for agent use.
Both repos are `.gitignore`d — clone them locally with:

```sh
git clone --depth 1 https://gitlab.com/etherlab.org/ethercat.git docs/references/igh
git clone --depth 1 https://github.com/OpenEtherCATsociety/SOEM.git docs/references/soem
```

---

## IgH EtherCAT Master (`igh/`)

Kernel module, C. Production-grade, most complete open-source implementation.
License: GPL-2 (reference only — do not copy verbatim into this Elixir library).

| Topic | File |
|-------|------|
| Slave config FSM: SM, FMMU, DC SYNC, CoE config sequence | `igh/master/fsm_slave_config.c` |
| Master FSM: scanning, DC init, propagation delay calc | `igh/master/fsm_master.c` |
| CoE SDO state machine: expedited download/upload, mailbox | `igh/master/fsm_coe.c` |
| Slave config structs: PDO, SM, FMMU, DC params | `igh/master/slave_config.c` |
| Slave struct: identity, ports, DC times | `igh/master/slave.c` |
| SII EEPROM state machine | `igh/master/fsm_sii.c` |
| PDO assignment/mapping FSM | `igh/master/fsm_pdo.c` |

### Key functions for active work

| Feature | Function | File |
|---------|----------|------|
| SYNC0/1 activation | `ec_fsm_slave_config_state_dc_cycle` | `fsm_slave_config.c` |
| DC propagation delay | `ec_master_calc_dc_delays` | `fsm_master.c` |
| System time offset | `ec_master_calc_dc_sync_times` | `fsm_master.c` |
| SDO expedited download | `ec_fsm_coe_down_start` → `ec_fsm_coe_down_response` | `fsm_coe.c` |
| FMMU config write | `ec_fsm_slave_config_state_fmmu` | `fsm_slave_config.c` |
| SM config write | `ec_fsm_slave_config_state_sync` | `fsm_slave_config.c` |

---

## SOEM (`soem/`)

Userspace C library. Simpler, more readable than IgH. Good for understanding
protocol mechanics without kernel module complexity.
License: LGPL-2.1.

| Topic | File |
|-------|------|
| DC: propagation delay, SYNC0/1 config, latch | `soem/src/ec_dc.c` |
| Master loop: scanning, state machine, cyclic I/O | `soem/src/ec_main.c` |
| CoE SDO: read/write, complete access | `soem/src/ec_coe.c` |
| FMMU/SM config, PDO mapping | `soem/src/ec_config.c` |
| Base datagrams: FPRD/FPWR/LRW/BRD/BWR | `soem/src/ec_base.c` |
| Type definitions: all register constants | `soem/include/ethercattype.h` |

### Key functions for active work

| Feature | Function | File |
|---------|----------|------|
| SYNC0 only | `ec_dcsync0` | `ec_dc.c` |
| SYNC0 + SYNC1 | `ec_dcsync01` | `ec_dc.c` |
| Full DC init | `ec_configdc` | `ec_dc.c` |
| Latch control | `ec_dclatch0` | `ec_dc.c` |
| SDO write | `ec_SDOwrite` | `ec_coe.c` |
| SDO read | `ec_SDOread` | `ec_coe.c` |
| State check/poll | `ec_statecheck` | `ec_main.c` |

---

## How to use these as an agent

When implementing a feature:

1. **Find the C equivalent** using the table above
2. **Read both implementations** — IgH and SOEM often differ in sequencing decisions
3. **Map to Elixir patterns**:

| C pattern | Elixir equivalent |
|-----------|-------------------|
| `ecrt_master_send` / `EC_WRITE_S8` register write | `Bus.transaction_queue(link, &Transaction.fpwr(&1, station, Registers.xxx(val)))` |
| `ec_datagram_fprd` + send + receive | `Bus.transaction_queue(link, &Transaction.fprd(&1, station, Registers.xxx()))` |
| `ecrt_domain_process` LRW loop | `Bus.transaction(link, &Transaction.lrw(&1, {base, image}))` |
| polling `while(status != target)` | `state_timeout` tick in gen_statem |
| `Bitwise.band(reg, 0x0F)` | `<<_::4, val::4, _::8>> = bytes` (binary pattern match) |
| ARMW drift correction | `Bus.transaction(link, &Transaction.armw(&1, ref_station, Registers.dc_system_time()))` |

4. **Never import Bitwise** — always binary pattern matching for bit fields.
5. **Register addresses** come from `lib/ethercat/slave/registers.ex` — add new ones there, never hardcode.
