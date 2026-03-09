defmodule EtherCAT do
  @moduledoc """
  Public API for the EtherCAT master runtime.

  `EtherCAT` is the entry point for a master-owned session lifecycle:

  - `Master` owns startup, activation-blocked startup, and recovery policy
  - `Domain` owns cyclic LRW exchange and the logical PDO image
  - `Slave` owns ESM transitions and slave-local configuration
  - `DC` owns distributed-clock initialization and runtime maintenance
  - `Bus` serializes all frame I/O

  Public session lifecycle is exposed through `state/0`:

  - `:idle`
  - `:discovering`
  - `:awaiting_preop`
  - `:preop_ready`
  - `:operational`
  - `:activation_blocked`
  - `:recovering`

  `await_running/1` waits for a usable session. `await_operational/1` waits for
  cyclic OP. Per-slave health is exposed through `slaves/0`.

  ## Runtime Lifecycle

  This is the public `state/0` lifecycle. It matches the actual `Master`
  states directly.

  ```mermaid
  stateDiagram-v2
      [*] --> idle
      idle --> discovering: start/1
      discovering --> awaiting_preop: configured slaves are still pending
      discovering --> preop_ready: startup completes without activation
      discovering --> operational: startup completes and activation succeeds
      discovering --> activation_blocked: startup completes but activation is incomplete
      discovering --> idle: configuration fails or stop/0
      awaiting_preop --> preop_ready: all slaves reached PREOP, no activation requested
      awaiting_preop --> operational: all slaves reached PREOP and activation succeeds
      awaiting_preop --> activation_blocked: all slaves reached PREOP but activation is incomplete
      awaiting_preop --> idle: timeout, activation failure, or stop/0
      preop_ready --> operational: activate/0 succeeds
      preop_ready --> activation_blocked: activate/0 is incomplete
      preop_ready --> idle: stop/0
      activation_blocked --> operational: retry clears activation failures and no runtime faults remain
      activation_blocked --> recovering: activation failures clear but runtime faults remain
      activation_blocked --> idle: stop/0 or bus down
      operational --> recovering: runtime fault in domain or DC
      operational --> idle: stop/0 or fatal failure
      recovering --> operational: runtime faults are cleared
      recovering --> idle: stop/0 or recovery fails
  ```

  ## Startup Sequence

  ```mermaid
  sequenceDiagram
      autonumber
      participant App
      participant Master
      participant Bus
      participant DC
      participant Domain
      participant Slave

      App->>Master: start/1
      Master->>Bus: count slaves, assign stations, verify link
      opt DC is configured
          Master->>DC: initialize clocks
      end
      Master->>Domain: start domains in open state
      Master->>Slave: start slave processes
      Slave->>Bus: reach PREOP through INIT, SII, and mailbox setup
      Slave->>Domain: register PDO layout
      Slave-->>Master: report ready at PREOP
      opt activation is requested and possible
          opt DC runtime is available
              Master->>DC: start runtime maintenance
          end
          Master->>Domain: start cyclic exchange
          opt DC lock is required
              Master->>DC: wait for lock
          end
          Master->>Slave: request SAFEOP
          Master->>Slave: request OP
      end
      Master-->>App: state becomes preop_ready or operational
  ```

  ## Usage

      EtherCAT.start(
        interface: "eth0",
        dc: %EtherCAT.DC.Config{
          cycle_ns: 1_000_000,
          await_lock?: true,
          lock_policy: :recovering
        },
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
  """

  alias EtherCAT.{Domain, Master, Slave}

  @doc "Return the stable bus server reference for direct frame transactions."
  @spec bus() :: EtherCAT.Bus.server() | nil | {:error, :not_started}
  def bus, do: Master.bus()

  @doc """
  Start the master: open the interface, discover slaves, and begin
  self-driving configuration.

  Returns `:ok` once discovery has started. Call `await_running/1` to block
  until startup finishes. If the master falls back to `:idle`, inspect
  `last_failure/0` for the retained reason. For dynamic PREOP workflows, call
  `activate/0` afterwards to enter cyclic operation.

  Options:
    - `:interface` (required) — network interface, e.g. `"eth0"`
    - `:domains` — list of `%EtherCAT.Domain.Config{}` structs describing
      domain intent. High-level domain configs do not take `:logical_base`;
      the master allocates logical windows automatically.
    - `:slaves` — list of `%EtherCAT.Slave.Config{}` structs
      (position matters — station address = `base_station + index`).
      `nil` entries are rejected; use `%EtherCAT.Slave.Config{name: :coupler}` for
      unnamed couplers. If omitted or empty, one default slave process is started
      per discovered station and held in `:preop` for dynamic configuration.
    - `:base_station` — first station address, default `0x1000`
    - `:dc` — `%EtherCAT.DC.Config{}` for master-wide Distributed Clocks, or
      `nil` to disable DC. `await_lock?` gates startup activation; `lock_policy`
      controls the runtime reaction to DC lock loss.
    - `:frame_timeout_ms` — optional fixed bus frame response timeout in ms
      (otherwise auto-tuned from slave count and cycle time)
    - `:scan_poll_ms` — optional discovery poll interval in ms
    - `:scan_stable_ms` — optional identical-count stability window in ms before startup begins
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: Master.start(opts)

  @doc "Stop the master: shut down all slaves, domains, and the bus. Returns `:already_stopped` if not running."
  @spec stop() :: :ok | :already_stopped
  def stop, do: Master.stop()

  @doc """
  Block until the master reaches a usable session state, then return `:ok`.

  Returns `{:error, :timeout}` if startup does not complete within `timeout_ms` ms.
  Returns `{:error, :not_started}` if `start/1` has not been called.
  Returns startup degradation or runtime recovery errors if the session is not
  currently usable.
  """
  @spec await_running(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_running(timeout_ms \\ 10_000), do: Master.await_running(timeout_ms)

  @doc """
  Block until the master reaches operational cyclic runtime, then return `:ok`.

  This is stricter than `await_running/1`: `:preop_ready` is not enough.
  """
  @spec await_operational(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_operational(timeout_ms \\ 10_000), do: Master.await_operational(timeout_ms)

  @doc """
  Return the current public session state.

  Values:
    - `:idle`
    - `:discovering`
    - `:awaiting_preop`
    - `:preop_ready`
    - `:operational` — cyclic OP path is healthy; inspect `slaves/0` for per-slave faults
    - `:activation_blocked` — startup/activation is blocked before operational cyclic runtime
    - `:recovering` — runtime fault recovery in progress
  """
  @spec state() ::
          :idle
          | :discovering
          | :awaiting_preop
          | :preop_ready
          | :operational
          | :activation_blocked
          | :recovering
  def state, do: Master.state()

  @doc """
  Return a Distributed Clocks status snapshot for the current session.

  Returns `{:error, :not_started}` if the master process does not exist.
  """
  @spec dc_status() :: EtherCAT.DC.Status.t() | {:error, :not_started}
  def dc_status, do: Master.dc_status()

  @doc "Return the current DC reference clock as `%{name, station}`."
  @spec reference_clock() ::
          {:ok, %{name: atom() | nil, station: non_neg_integer()}} | {:error, term()}
  def reference_clock, do: Master.reference_clock()

  @doc """
  Wait for DC lock.

  Returns `:ok` once the active DC runtime reports `:locked`.
  """
  @spec await_dc_locked(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_dc_locked(timeout_ms \\ 5_000), do: Master.await_dc_locked(timeout_ms)

  @doc """
  Return the last terminal startup/runtime failure retained after the master
  returned to `:idle`.
  """
  @spec last_failure() :: map() | nil
  def last_failure, do: Master.last_failure()

  @doc """
  Configure a discovered slave while the session is still in PREOP.

  This is the dynamic counterpart to providing `%EtherCAT.Slave.Config{}` entries
  up front in `start/1`.
  """
  @spec configure_slave(atom(), keyword() | EtherCAT.Slave.Config.t()) :: :ok | {:error, term()}
  def configure_slave(slave_name, opts), do: Master.configure_slave(slave_name, opts)

  @doc """
  Start cyclic operation after dynamic PREOP configuration.

  This starts the DC runtime, starts all domains cycling, and advances all slaves
  whose `target_state` is `:op`.
  """
  @spec activate() :: :ok | {:error, term()}
  def activate, do: Master.activate()

  @doc "Return `[%{name:, station:, server:, pid:, fault:}]` for all running slaves."
  @spec slaves() ::
          [
            %{
              name: atom(),
              station: non_neg_integer(),
              server: :gen_statem.server_ref(),
              pid: pid() | nil,
              fault: term() | nil
            }
          ]
          | {:error, :not_started}
  def slaves, do: Master.slaves()

  @doc "Return `[{id, cycle_time_us, pid}]` for all running domains."
  @spec domains() :: list()
  def domains, do: Master.domains()

  @doc """
  Update the live cycle period of a running domain.

  This changes the `Domain` runtime directly. The master keeps its initial
  domain plan; `domains/0` and `domain_info/1` reflect the live period owned by
  the `Domain` process.
  """
  @spec update_domain_cycle_time(atom(), pos_integer()) :: :ok | {:error, term()}
  def update_domain_cycle_time(domain_id, cycle_time_us),
    do: Master.update_domain_cycle_time(domain_id, cycle_time_us)

  @doc """
  Return a diagnostic snapshot for a slave.

  Keys:
    - `:name` — slave atom name
    - `:station` — assigned bus station address
    - `:al_state` — current ESM state: `:init | :preop | :safeop | :op`
    - `:identity` — `%{vendor_id, product_code, revision, serial_number}` from SII, or `nil`
    - `:esc` — `%{fmmu_count, sm_count}` from ESC base registers, or `nil`
    - `:driver` — driver module in use
    - `:coe` — `true` if the slave has a mailbox (CoE-capable)
    - `:available_fmmus` — FMMUs supported by the ESC, or `nil`
    - `:used_fmmus` — count of active `{domain, SyncManager}` attachments
    - `:attachments` — list of `%{domain, sm_index, direction, logical_address, sm_size, signal_count, signals}`
    - `:signals` — list of `%{name, domain, direction, bit_offset, bit_size}` for registered signals
    - `:configuration_error` — last configuration failure atom, or `nil`

  ## Example

      iex> EtherCAT.slave_info(:sensor)
      {:ok, %{
        name: :sensor,
        station: 0x1001,
        al_state: :op,
        identity: %{vendor_id: 0x2, product_code: 0x07111389, revision: 0x00190000, serial_number: 0},
        esc: %{fmmu_count: 3, sm_count: 4},
        driver: MyApp.EL1809,
        coe: false,
        available_fmmus: 3,
        used_fmmus: 1,
        attachments: [
          %{domain: :main, sm_index: 3, direction: :input, logical_address: 0x0000, sm_size: 2, signal_count: 2, signals: [:ch1, :ch2]}
        ],
        signals: [
          %{name: :ch1, domain: :main, direction: :input, bit_offset: 0, bit_size: 1},
          ...
        ],
        configuration_error: nil
      }}
  """
  @spec slave_info(atom()) :: {:ok, map()} | {:error, :not_found}
  def slave_info(slave_name), do: Slave.info(slave_name)

  @doc """
  Return a diagnostic snapshot for a domain.

  Keys:
    - `:id` — domain atom identifier
    - `:cycle_time_us` — current cycle period in microseconds
    - `:state` — `:open | :cycling | :stopped`
    - `:cycle_count` — successful LRW cycles since last start
    - `:miss_count` — consecutive missed cycles (resets on success)
    - `:total_miss_count` — cumulative missed cycles since last start
    - `:logical_base` — current LRW logical start address for this domain image
    - `:image_size` — PDO image size in bytes
    - `:expected_wkc` — expected working counter for a healthy bus

  ## Example

      iex> EtherCAT.domain_info(:main)
      {:ok, %{
        id: :main,
        cycle_time_us: 1_000,
        state: :cycling,
        cycle_count: 12345,
        miss_count: 0,
        total_miss_count: 2,
        logical_base: 0,
        image_size: 4,
        expected_wkc: 3
      }}
  """
  @spec domain_info(atom()) :: {:ok, map()} | {:error, term()}
  def domain_info(domain_id), do: Domain.info(domain_id)

  @doc """
  Subscribe to named slave events.

  `name` may refer to:

    - a registered process-data signal, delivered as
      `{:ethercat, :signal, slave_name, name, value}`
    - a named latch configured through `sync.latches`, delivered as
      `{:ethercat, :latch, slave_name, name, timestamp_ns}`
  """
  @spec subscribe(atom(), atom(), pid()) :: :ok | {:error, :not_found}
  def subscribe(slave_name, name, pid \\ self()),
    do: Slave.subscribe(slave_name, name, pid)

  @doc """
  Stage `value` into a slave output PDO for the next domain cycle.

  This confirms the value was staged into the master's domain output buffer for
  the next cycle. It does not prove the slave has already applied the value on
  hardware.
  """
  @spec write_output(atom(), atom(), term()) :: :ok | {:error, term()}
  def write_output(slave_name, pdo_name, value),
    do: Slave.write_output(slave_name, pdo_name, value)

  @doc """
  Read the latest decoded input sample for a slave input signal.

  This returns the last process-image value observed by the master, not a direct
  wire read and not an exact hardware-edge timestamp. Exact event timing requires
  device-specific timestamped PDOs or ESC LATCH support, not the generic PDO API.

  Returns `{:error, :not_ready}` until the first domain cycle completes.
  """
  @spec read_input(atom(), atom()) ::
          {:ok, %{value: term(), updated_at_us: integer() | nil}} | {:error, term()}
  def read_input(slave_name, pdo_name),
    do: Slave.read_input(slave_name, pdo_name)

  @doc """
  Download a CoE SDO value to a slave mailbox object entry.

  This is a blocking acyclic mailbox transfer and is only valid once the slave
  mailbox is configured, typically from PREOP onward.
  """
  @spec download_sdo(atom(), non_neg_integer(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def download_sdo(slave_name, index, subindex, data),
    do: Slave.download_sdo(slave_name, index, subindex, data)

  @doc """
  Upload a CoE SDO value from a slave mailbox object entry.

  This is a blocking acyclic mailbox transfer and is only valid once the slave
  mailbox is configured, typically from PREOP onward.
  """
  @spec upload_sdo(atom(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def upload_sdo(slave_name, index, subindex),
    do: Slave.upload_sdo(slave_name, index, subindex)
end
