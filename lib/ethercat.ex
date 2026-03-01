defmodule EtherCAT do
  @moduledoc """
  Public API for the EtherCAT master runtime.

  ## Usage

      EtherCAT.start(
        interface: "eth0",
        domains: [
          %EtherCAT.Domain.Config{id: :main, period: 1}
        ],
        slaves: [
          nil,
          %EtherCAT.Slave.Config{name: :sensor, driver: MyApp.EL1809, domain: :main},
          %EtherCAT.Slave.Config{name: :valve,  driver: MyApp.EL2809, domain: :main}
        ]
      )

      :ok = EtherCAT.await_running()

      EtherCAT.subscribe(:sensor, :ch1)   # receive {:slave_input, :sensor, :ch1, value}
      EtherCAT.set_output(:valve, :ch1, 1)

      EtherCAT.stop()

  ## Sub-modules

  `EtherCAT.Slave`, `EtherCAT.Domain`, `EtherCAT.Link` — raw slave control,
  domain stats, and direct frame transactions.
  """

  alias EtherCAT.{Master, Slave}

  @doc "Return the link pid for direct frame transactions."
  @spec link() :: pid()
  def link, do: Master.link()

  @doc """
  Start the master: open the interface, scan for slaves, and begin
  self-driving configuration.

  Returns `:ok` once scanning has started. Call `await_running/1` to block
  until the bus is fully operational.

  Options:
    - `:interface` (required) — network interface, e.g. `"eth0"`
    - `:domains` — list of `%EtherCAT.Domain.Config{}` structs
    - `:slaves` — list of `%EtherCAT.Slave.Config{}` structs or `nil`
      (position matters — station address = `base_station + index`)
    - `:base_station` — first station address, default `0x1000`
    - `:dc_cycle_ns` — SYNC0 cycle time in ns, default `1_000_000`
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: Master.start(opts)

  @doc "Stop the master: shut down all slaves, domains, and the link."
  @spec stop() :: :ok
  def stop, do: Master.stop()

  @doc """
  Block until the master reaches `:running`, then return `:ok`.

  Returns `{:error, :timeout}` if not operational within `timeout_ms` ms.
  Returns `{:error, :not_started}` if `start/1` has not been called.
  """
  @spec await_running(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_running(timeout_ms \\ 10_000), do: Master.await_running(timeout_ms)

  @doc "Return the current master state: `:idle | :scanning | :configuring | :running`."
  @spec state() :: atom()
  def state, do: Master.state()

  @doc "Return `[{name, station, pid}]` for all running slaves."
  @spec slaves() :: list()
  def slaves, do: Master.slaves()

  @doc """
  Subscribe to decoded input change notifications from a slave PDO.

  Messages arrive as `{:slave_input, slave_name, pdo_name, value}`.
  Defaults to `self()`.
  """
  @spec subscribe(atom(), atom(), pid()) :: :ok
  def subscribe(slave_name, pdo_name, pid \\ self()),
    do: Slave.subscribe(slave_name, pdo_name, pid)

  @doc """
  Write `value` to a slave output PDO. Encodes via the driver and writes
  to the domain output buffer directly (no gen_statem hop).
  """
  @spec set_output(atom(), atom(), term()) :: :ok | {:error, term()}
  def set_output(slave_name, pdo_name, value),
    do: Slave.set_output(slave_name, pdo_name, value)

  @doc """
  Read the decoded input value for a slave PDO. Equivalent to the value
  delivered by `subscribe/2`, but as a one-shot synchronous call.

  Returns `{:error, :not_ready}` until the first domain cycle completes.
  """
  @spec read_input(atom(), atom()) :: {:ok, term()} | {:error, term()}
  def read_input(slave_name, pdo_name),
    do: Slave.read_input(slave_name, pdo_name)
end
