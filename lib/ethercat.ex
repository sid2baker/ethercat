defmodule EtherCAT do
  @moduledoc File.read!(Path.join(__DIR__, "ethercat.md"))

  alias EtherCAT.{Domain, Master, Slave}

  @doc "Return the bus pid for direct frame transactions."
  @spec bus() :: pid()
  def bus, do: Master.bus()

  @doc """
  Start the master: open the interface, scan for slaves, and begin
  self-driving configuration.

  Returns `:ok` once scanning has started. Call `await_running/1` to block
  until startup finishes. If the master falls back to `:idle`, inspect
  `last_failure/0` for the retained reason. For dynamic PREOP workflows, call
  `activate/0` afterwards to enter cyclic operation.

  Options:
    - `:interface` (required) — network interface, e.g. `"eth0"`
    - `:domains` — list of `%EtherCAT.Domain.Config{}` structs
    - `:slaves` — list of `%EtherCAT.Slave.Config{}` structs
      (position matters — station address = `base_station + index`).
      `nil` entries are rejected; use `%EtherCAT.Slave.Config{name: :coupler}` for
      unnamed couplers. If omitted or empty, one default slave process is started
      per discovered station and held in `:preop` for dynamic configuration.
    - `:base_station` — first station address, default `0x1000`
    - `:dc` — `%EtherCAT.DC.Config{}` for master-wide Distributed Clocks, or `nil` to disable DC
    - `:frame_timeout_ms` — optional fixed bus frame response timeout in ms
      (otherwise auto-tuned from slave count and cycle time)
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: Master.start(opts)

  @doc "Stop the master: shut down all slaves, domains, and the bus. Returns `:already_stopped` if not running."
  @spec stop() :: :ok | :already_stopped
  def stop, do: Master.stop()

  @doc """
  Block until the master reaches `:running`, then return `:ok`.

  Returns `{:error, :timeout}` if startup does not complete within `timeout_ms` ms.
  Returns `{:error, :not_started}` if `start/1` has not been called.
  """
  @spec await_running(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_running(timeout_ms \\ 10_000), do: Master.await_running(timeout_ms)

  @doc """
  Block until the master reaches operational cyclic runtime, then return `:ok`.

  This is stricter than `await_running/1`: `:preop_ready` is not enough.
  """
  @spec await_operational(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_operational(timeout_ms \\ 10_000), do: Master.await_operational(timeout_ms)

  @doc "Return the current master state: `:idle | :scanning | :configuring | :running | :degraded`."
  @spec state() :: atom()
  def state, do: Master.state()

  @doc """
  Return the current public session phase.

  Values:
    - `:idle`
    - `:scanning`
    - `:configuring`
    - `:preop_ready`
    - `:operational`
    - `:degraded`
  """
  @spec phase() :: :idle | :scanning | :configuring | :preop_ready | :operational | :degraded
  def phase, do: Master.phase()

  @doc "Return a Distributed Clocks status snapshot for the current session."
  @spec dc_status() :: EtherCAT.DC.Status.t()
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

  @doc "Return `[%{name:, station:, pid:}]` for all running slaves."
  @spec slaves() ::
          [%{name: atom(), station: non_neg_integer(), pid: pid()}] | {:error, :not_started}
  def slaves, do: Master.slaves()

  @doc "Return `[{id, cycle_time_us, pid}]` for all running domains."
  @spec domains() :: list()
  def domains, do: Master.domains()

  @doc """
  Return a diagnostic snapshot for a slave.

  Keys:
    - `:name` — slave atom name
    - `:station` — assigned bus station address
    - `:al_state` — current ESM state: `:init | :preop | :safeop | :op`
    - `:identity` — `%{vendor_id, product_code, revision, serial_number}` from SII, or `nil`
    - `:driver` — driver module in use
    - `:coe` — `true` if the slave has a mailbox (CoE-capable)
    - `:signals` — list of `%{name, domain, direction, bit_offset, bit_size}` for registered signals
    - `:configuration_error` — last configuration failure atom, or `nil`

  ## Example

      iex> EtherCAT.slave_info(:sensor)
      {:ok, %{
        name: :sensor,
        station: 0x1001,
        al_state: :op,
        identity: %{vendor_id: 0x2, product_code: 0x07111389, revision: 0x00190000, serial_number: 0},
        driver: MyApp.EL1809,
        coe: false,
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
  @spec read_input(atom(), atom()) :: {:ok, term()} | {:error, term()}
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
