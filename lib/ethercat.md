Public API for the EtherCAT master runtime.

## Usage

    EtherCAT.start(
      interface: "eth0",
      dc: %EtherCAT.DC.Config{cycle_ns: 1_000_000},
      domains: [
        %EtherCAT.Domain.Config{id: :main, cycle_time_us: 1_000}
      ],
      slaves: [
        %EtherCAT.Slave.Config{name: :coupler},
        %EtherCAT.Slave.Config{
          name: :sensor,
          driver: MyApp.EL1809,
          process_data: {:all, :main}
        },
        %EtherCAT.Slave.Config{
          name: :valve,
          driver: MyApp.EL2809,
          process_data: {:all, :main}
        }
      ]
    )

    :ok = EtherCAT.await_running()

    EtherCAT.subscribe(:sensor, :ch1)   # receive {:ethercat, :signal, :sensor, :ch1, value}
    EtherCAT.write_output(:valve, :ch1, 1)

    EtherCAT.stop()

## Dynamic PREOP Configuration

    EtherCAT.start(
      interface: "eth0",
      domains: [%EtherCAT.Domain.Config{id: :main, cycle_time_us: 1_000}]
    )

    :ok = EtherCAT.await_running()

    :ok =
      EtherCAT.configure_slave(
        :slave_1,
        driver: MyApp.EL1809,
        process_data: {:all, :main},
        target_state: :op
      )

    :ok = EtherCAT.activate()
    :ok = EtherCAT.await_operational()

## Sub-modules

`EtherCAT.Slave`, `EtherCAT.Domain`, `EtherCAT.Bus` — raw slave control,
domain stats, and direct frame transactions.
