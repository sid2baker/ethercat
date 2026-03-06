defmodule EtherCAT do
  @moduledoc """
  Public API for the EtherCAT master runtime.

  ## Usage

      EtherCAT.start(
        interface: "eth0",
        domains: [
          %EtherCAT.Domain.Config{id: :main, period_ms: 1}
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

      EtherCAT.subscribe_input(:sensor, :ch1)   # receive {:slave_input, :sensor, :ch1, value}
      EtherCAT.write_output(:valve, :ch1, 1)

      EtherCAT.stop()

  ## Dynamic PREOP Configuration

      EtherCAT.start(
        interface: "eth0",
        domains: [%EtherCAT.Domain.Config{id: :main, period_ms: 1}]
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

  alias EtherCAT.{Master, Slave}

  @doc "Return the bus pid for direct frame transactions."
  @spec bus() :: pid()
  def bus, do: Master.bus()

  @doc """
  Start the master: open the interface, scan for slaves, and begin
  self-driving configuration.

  Returns `:ok` once scanning has started. Call `await_running/1` to block
  until startup finishes. For dynamic PREOP workflows, call `activate/0`
  afterwards to enter cyclic operation.

  Options:
    - `:interface` (required) — network interface, e.g. `"eth0"`
    - `:domains` — list of `%EtherCAT.Domain.Config{}` structs
    - `:slaves` — list of `%EtherCAT.Slave.Config{}` structs
      (position matters — station address = `base_station + index`).
      `nil` entries are rejected; use `%EtherCAT.Slave.Config{name: :coupler}` for
      unnamed couplers. If omitted or empty, one default slave process is started
      per discovered station and held in `:preop` for dynamic configuration.
    - `:base_station` — first station address, default `0x1000`
    - `:dc_cycle_ns` — SYNC0 cycle time in ns, default `1_000_000`
    - `:frame_timeout_ms` — optional fixed bus frame response timeout in ms
      (otherwise auto-tuned from slave count and cycle time)
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: Master.start(opts)

  @doc "Stop the master: shut down all slaves, domains, and the bus."
  @spec stop() :: :ok
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

  @doc "Return `[{name, station, pid}]` for all running slaves."
  @spec slaves() :: list()
  def slaves, do: Master.slaves()

  @doc """
  Subscribe to decoded input change notifications from a slave PDO.

  Messages arrive as `{:slave_input, slave_name, pdo_name, value}`.
  Defaults to `self()`.
  """
  @spec subscribe_input(atom(), atom(), pid()) :: :ok
  def subscribe_input(slave_name, pdo_name, pid \\ self()),
    do: Slave.subscribe_input(slave_name, pdo_name, pid)

  @doc """
  Stage `value` into a slave output PDO for the next domain cycle.

  This does not toggle hardware immediately. It encodes via the driver and writes
  to the domain output buffer directly (no gen_statem hop).
  """
  @spec write_output(atom(), atom(), term()) :: :ok | {:error, term()}
  def write_output(slave_name, pdo_name, value),
    do: Slave.write_output(slave_name, pdo_name, value)

  @doc """
  Read the latest decoded input sample for a slave PDO.

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
