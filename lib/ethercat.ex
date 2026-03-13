defmodule EtherCAT do
  @moduledoc """
  Public API for the EtherCAT master runtime.

  `EtherCAT` is the entry point for a master-owned session lifecycle:

  - `Master` owns startup, activation-blocked startup, and recovery policy
  - `Domain` owns cyclic LRW exchange and the logical PDO image
  - `Slave` owns ESM transitions and slave-local configuration
  - `DC` owns distributed-clock initialization and runtime maintenance
  - `Bus` serializes all frame I/O

  Runtime footprint is intentionally small: no NIFs, no kernel module, and a
  minimal runtime dependency surface. The bus uses raw sockets, sysfs, and OTP
  directly, with `:telemetry` as the only runtime Hex dependency.

  Public session lifecycle is exposed through `state/0`:

  - `:idle`
  - `:discovering`
  - `:awaiting_preop`
  - `:preop_ready`
  - `:deactivated`
  - `:operational`
  - `:activation_blocked`
  - `:recovering`

  `await_running/1` waits for a usable session. Startup/activation paths drain
  startup bus traffic before reporting ready, so the first mailbox or OP
  exchange starts from a clean transport state. `await_operational/1` waits for
  cyclic OP. Per-slave health is exposed through `slaves/0`.

  ## Runtime Lifecycle

  This is the user-facing `state/0` lifecycle. It shows the main session flow
  without trying to encode every exact `Master` state transition in one dense
  graph.

  ```mermaid
  flowchart TD
      A[start/1] --> B[discovering]
      B --> C[awaiting_preop]
      B -->|startup fails or stop/0| Z[idle]
      C -->|configured slaves become usable in PREOP| D{activation requested?}
      C -->|timeout, fatal startup failure, or stop/0| Z

      D -->|no| E[preop_ready]
      D -->|yes, target reached| F[operational]
      D -->|yes, transition incomplete| G[activation_blocked]

      E -->|activate/0 succeeds| F
      E -->|activate/0 is incomplete| G

      F -->|deactivate/0 to SAFEOP| H[deactivated]
      F -->|deactivate/0 to PREOP| E

      E -->|critical runtime fault| I[recovering]
      H -->|critical runtime fault| I
      F -->|critical runtime fault| I
      G -->|runtime faults remain after activation retry| I

      G -->|retry reaches OP| F
      G -->|retry settles in SAFEOP| H
      G -->|retry settles in PREOP| E

      I -->|faults cleared, target OP| F
      I -->|faults cleared, target SAFEOP| H
      I -->|faults cleared, target PREOP| E

      E -->|stop/0 or fatal exit| Z
      H -->|stop/0 or fatal exit| Z
      F -->|stop/0 or fatal exit| Z
      G -->|stop/0 or fatal exit| Z
      I -->|recovery fails or stop/0| Z
  ```

  Physical link loss normally appears here as a runtime `:recovering` transition,
  not an immediate return to `:idle`. `:idle` is reserved for explicit stop,
  startup failure, bus-process exit, or fatal policy. For the exact master-side
  state semantics, read `EtherCAT.Master`.

  ## Startup Sequence

  ```mermaid
  sequenceDiagram
      autonumber
      participant App
      participant EtherCAT
      participant Bus
      participant Slaves
      participant DC

      App->>EtherCAT: start/1
      EtherCAT->>Bus: discover ring, assign stations, verify link
      opt DC is configured
          EtherCAT->>DC: initialize clocks
      end
      EtherCAT->>Slaves: start configured slaves
      Slaves->>Bus: reach PREOP through SII, mailbox, and PDO setup
      Slaves-->>EtherCAT: report ready at PREOP
      opt activation is requested and possible
          EtherCAT->>Bus: start cyclic domains
          opt DC runtime is available
              EtherCAT->>DC: start runtime maintenance
              opt DC lock is required
                  EtherCAT->>DC: wait for lock
              end
          end
          EtherCAT->>Slaves: request SAFEOP then OP
      end
      EtherCAT-->>App: preop_ready, activation_blocked, or operational
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

      EtherCAT.deactivate()
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

  `EtherCAT.Slave.API`, `EtherCAT.Domain.API`, `EtherCAT.DC.API`, `EtherCAT.Bus`
  — low-level slave control, domain/runtime helpers, and direct frame
  transactions.
  """

  alias EtherCAT.Domain.API, as: DomainAPI
  alias EtherCAT.Master.API, as: MasterAPI
  alias EtherCAT.Slave.API, as: SlaveAPI

  @typedoc """
  Public master session states returned by `state/0` once the local query
  succeeds.
  """
  @type session_state ::
          :idle
          | :discovering
          | :awaiting_preop
          | :preop_ready
          | :deactivated
          | :operational
          | :activation_blocked
          | :recovering

  @typedoc """
  Local wrapper errors returned when a synchronous master query cannot complete.

  These are transport-level API failures, not session lifecycle states.
  """
  @type master_query_error :: {:error, :not_started | :timeout}

  @typedoc "Direction of a registered process-data signal."
  @type signal_direction :: :input | :output

  @typedoc "AL state reported in `slave_info/1`."
  @type slave_al_state :: :init | :preop | :safeop | :op

  @typedoc "Runtime state reported in `domain_info/1`."
  @type domain_runtime_state :: :open | :cycling | :stopped

  @typedoc "Cycle health reported by `domain_info/1`."
  @type domain_cycle_health :: :healthy | {:invalid, term()}

  @typedoc "Identity snapshot reported in `slave_info/1`."
  @type slave_identity :: %{
          required(:vendor_id) => non_neg_integer(),
          required(:product_code) => non_neg_integer(),
          required(:revision) => non_neg_integer(),
          required(:serial_number) => non_neg_integer()
        }

  @typedoc "ESC capability snapshot reported in `slave_info/1`."
  @type slave_esc_info :: %{
          required(:fmmu_count) => non_neg_integer(),
          required(:sm_count) => non_neg_integer()
        }

  @typedoc "SyncManager attachment summary reported in `slave_info/1`."
  @type slave_attachment_summary :: %{
          required(:domain) => EtherCAT.Domain.domain_id(),
          required(:sm_index) => non_neg_integer(),
          required(:direction) => signal_direction(),
          required(:logical_address) => non_neg_integer() | nil,
          required(:sm_size) => non_neg_integer() | nil,
          required(:signal_count) => non_neg_integer(),
          required(:signals) => [atom()]
        }

  @typedoc "Signal registration summary reported in `slave_info/1`."
  @type slave_signal_summary :: %{
          required(:name) => atom(),
          required(:domain) => EtherCAT.Domain.domain_id(),
          required(:direction) => signal_direction(),
          required(:sm_index) => non_neg_integer(),
          required(:bit_offset) => non_neg_integer(),
          required(:bit_size) => pos_integer()
        }

  @typedoc "Compact slave summary returned by `slaves/0`."
  @type slave_summary :: %{
          required(:name) => atom(),
          required(:station) => non_neg_integer(),
          required(:server) => :gen_statem.server_ref(),
          required(:pid) => pid() | nil,
          required(:fault) => term() | nil
        }

  @typedoc "Compact domain summary returned by `domains/0`."
  @type domain_summary :: {EtherCAT.Domain.domain_id(), pos_integer(), pid()}

  @typedoc "Detailed snapshot returned by `slave_info/1`."
  @type slave_info :: %{
          required(:name) => atom(),
          required(:station) => non_neg_integer(),
          required(:al_state) => slave_al_state(),
          required(:identity) => slave_identity() | nil,
          required(:esc) => slave_esc_info() | nil,
          required(:driver) => module() | nil,
          required(:coe) => boolean(),
          required(:available_fmmus) => non_neg_integer() | nil,
          required(:used_fmmus) => non_neg_integer(),
          required(:attachments) => [slave_attachment_summary()],
          required(:signals) => [slave_signal_summary()],
          required(:configuration_error) => term() | nil
        }

  @typedoc "Detailed snapshot returned by `domain_info/1`."
  @type domain_info :: %{
          required(:id) => EtherCAT.Domain.domain_id(),
          required(:cycle_time_us) => pos_integer(),
          required(:state) => domain_runtime_state(),
          required(:cycle_count) => non_neg_integer(),
          required(:miss_count) => non_neg_integer(),
          required(:total_miss_count) => non_neg_integer(),
          required(:cycle_health) => domain_cycle_health(),
          required(:logical_base) => non_neg_integer(),
          required(:image_size) => non_neg_integer(),
          required(:expected_wkc) => non_neg_integer(),
          required(:last_cycle_started_at_us) => integer() | nil,
          required(:last_cycle_completed_at_us) => integer() | nil,
          required(:last_valid_cycle_at_us) => integer() | nil,
          required(:last_invalid_cycle_at_us) => integer() | nil,
          required(:last_invalid_reason) => term() | nil
        }

  @doc """
  Return the stable bus server reference for direct frame transactions.

  Returns `Bus` while the session owns a running bus process.
  Returns `nil` if the master process exists but the bus subsystem is not
  currently running, such as after the session has settled back to `:idle`.

  Returns `{:error, :not_started}` if the master does not exist and
  `{:error, :timeout}` if the local master call itself times out.
  """
  @spec bus() :: EtherCAT.Bus.server() | nil | master_query_error()
  def bus, do: MasterAPI.bus()

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
  def start(opts \\ []), do: MasterAPI.start(opts)

  @doc "Stop the master: tear the session down completely. Returns `:already_stopped` if not running."
  @spec stop() :: :ok | :already_stopped
  def stop, do: MasterAPI.stop()

  @doc """
  Block until the master reaches a usable session state, then return `:ok`.

  Returns `{:error, :timeout}` if startup does not complete within `timeout_ms` ms.
  Returns `{:error, :not_started}` if `start/1` has not been called.
  Returns startup degradation or runtime recovery errors if the session is not
  currently usable.
  """
  @spec await_running(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_running(timeout_ms \\ 10_000), do: MasterAPI.await_running(timeout_ms)

  @doc """
  Block until the master reaches operational cyclic runtime, then return `:ok`.

  This is stricter than `await_running/1`: `:preop_ready` and `:deactivated`
  are not enough.
  """
  @spec await_operational(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_operational(timeout_ms \\ 10_000), do: MasterAPI.await_operational(timeout_ms)

  @doc """
  Return the current public session state.

  Values:
    - `:idle`
    - `:discovering`
    - `:awaiting_preop`
    - `:preop_ready`
    - `:deactivated` — session is live but intentionally settled below OP, typically SAFEOP
    - `:operational` — cyclic OP path is healthy; inspect `slaves/0` for non-critical per-slave faults
    - `:activation_blocked` — the transition to the desired runtime target is blocked
    - `:recovering` — runtime fault recovery in progress

  `:idle` means the master process exists and the session is idle.
  `{:error, :not_started}` means there is no local master process at all.

  Returns `{:error, :not_started}` if the master does not exist and
  `{:error, :timeout}` if the local master call itself times out.
  """
  @spec state() :: session_state() | master_query_error()
  def state, do: MasterAPI.state()

  @doc """
  Return a Distributed Clocks status snapshot for the current session.

  Returns `{:error, :not_started}` if the master process does not exist.
  Returns `{:error, :timeout}` if the local master call itself times out.
  """
  @spec dc_status() :: EtherCAT.DC.Status.t() | master_query_error()
  def dc_status, do: MasterAPI.dc_status()

  @doc "Return the current DC reference clock as `%{name, station}`."
  @spec reference_clock() ::
          {:ok, %{name: atom() | nil, station: non_neg_integer()}} | {:error, term()}
  def reference_clock, do: MasterAPI.reference_clock()

  @doc """
  Wait for DC lock.

  Returns `:ok` once the active DC runtime reports `:locked`.
  """
  @spec await_dc_locked(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_dc_locked(timeout_ms \\ 5_000), do: MasterAPI.await_dc_locked(timeout_ms)

  @doc """
  Return the last terminal startup/runtime failure retained after the master
  returned to `:idle`.

  Returns `{:error, :not_started}` if the master does not exist and
  `{:error, :timeout}` if the local master call itself times out.
  """
  @spec last_failure() :: map() | nil | master_query_error()
  def last_failure, do: MasterAPI.last_failure()

  @doc """
  Configure a discovered slave while the session is still in PREOP.

  This is the dynamic counterpart to providing `%EtherCAT.Slave.Config{}` entries
  up front in `start/1`.
  """
  @spec configure_slave(atom(), keyword() | EtherCAT.Slave.Config.t()) :: :ok | {:error, term()}
  def configure_slave(slave_name, opts), do: MasterAPI.configure_slave(slave_name, opts)

  @doc """
  Start cyclic operation after dynamic PREOP configuration.

  This starts the DC runtime, starts all domains cycling, and advances all slaves
  whose `target_state` is `:op`.
  """
  @spec activate() :: :ok | {:error, term()}
  def activate, do: MasterAPI.activate()

  @doc """
  Leave OP while keeping the session alive.

  `deactivate/0` settles the runtime in SAFEOP by default. Use
  `deactivate(:preop)` when you need to re-enter PREOP for reconfiguration.
  """
  @spec deactivate(:safeop | :preop) :: :ok | {:error, term()}
  def deactivate(target \\ :safeop), do: MasterAPI.deactivate(target)

  @doc """
  Return `[%{name:, station:, server:, pid:, fault:}]` for all running slaves.

  Returns `{:error, :not_started}` if the master does not exist and
  `{:error, :timeout}` if the local master call itself times out.
  """
  @spec slaves() :: [slave_summary()] | master_query_error()
  def slaves, do: MasterAPI.slaves()

  @doc """
  Return `[{id, cycle_time_us, pid}]` for all running domains.

  Returns `{:error, :not_started}` if the master does not exist and
  `{:error, :timeout}` if the local master call itself times out.
  """
  @spec domains() :: [domain_summary()] | master_query_error()
  def domains, do: MasterAPI.domains()

  @doc """
  Update the live cycle period of a running domain.

  This changes the `Domain` runtime directly. The master keeps its initial
  domain plan; `domains/0` and `domain_info/1` reflect the live period owned by
  the `Domain` process.
  """
  @spec update_domain_cycle_time(atom(), pos_integer()) :: :ok | {:error, term()}
  def update_domain_cycle_time(domain_id, cycle_time_us),
    do: MasterAPI.update_domain_cycle_time(domain_id, cycle_time_us)

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
    - `:configuration_error` — last configuration failure term, or `nil`
      Common values are structured tuples such as
      `{:mailbox_config_failed, index, subindex, reason}`.

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
  @spec slave_info(atom()) :: {:ok, slave_info()} | {:error, :not_found | :timeout}
  def slave_info(slave_name), do: SlaveAPI.info(slave_name)

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
  @spec domain_info(atom()) :: {:ok, domain_info()} | {:error, :not_found | :timeout}
  def domain_info(domain_id), do: DomainAPI.info(domain_id)

  @doc """
  Subscribe to named slave events.

  `name` may refer to:

    - a registered process-data signal, delivered as
      `{:ethercat, :signal, slave_name, name, value}`
    - a named latch configured through `sync.latches`, delivered as
      `{:ethercat, :latch, slave_name, name, timestamp_ns}`
  """
  @spec subscribe(atom(), atom(), pid()) :: :ok | {:error, :not_found | :timeout}
  def subscribe(slave_name, name, pid \\ self()),
    do: SlaveAPI.subscribe(slave_name, name, pid)

  @doc """
  Stage `value` into a slave output PDO for the next domain cycle.

  This confirms the value was staged into the master's domain output buffer for
  the next cycle. It does not prove the slave has already applied the value on
  hardware.
  """
  @spec write_output(atom(), atom(), term()) :: :ok | {:error, term()}
  def write_output(slave_name, pdo_name, value),
    do: SlaveAPI.write_output(slave_name, pdo_name, value)

  @doc """
  Read the latest decoded input sample for a slave input signal.

  Returns `{value, updated_at_us}` where `updated_at_us` is the last valid
  master refresh time for the cached process-image sample, not a hardware-edge
  timestamp.

  Returns `{:error, :not_ready}` until the first domain cycle completes.
  """
  @spec read_input(atom(), atom()) :: {:ok, {term(), integer()}} | {:error, term()}
  def read_input(slave_name, pdo_name),
    do: SlaveAPI.read_input(slave_name, pdo_name)

  @doc """
  Download a CoE SDO value to a slave mailbox object entry.

  This is a blocking acyclic mailbox transfer and is only valid once the slave
  mailbox is configured, typically from PREOP onward.
  """
  @spec download_sdo(atom(), non_neg_integer(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def download_sdo(slave_name, index, subindex, data),
    do: SlaveAPI.download_sdo(slave_name, index, subindex, data)

  @doc """
  Upload a CoE SDO value from a slave mailbox object entry.

  This is a blocking acyclic mailbox transfer and is only valid once the slave
  mailbox is configured, typically from PREOP onward.
  """
  @spec upload_sdo(atom(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def upload_sdo(slave_name, index, subindex),
    do: SlaveAPI.upload_sdo(slave_name, index, subindex)
end
