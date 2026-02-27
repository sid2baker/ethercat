defmodule EtherCAT do
  @moduledoc """
  Public API for the EtherCAT master runtime.

  ## Typical usage

      # 1. Configure and start — scans bus, assigns stations, initialises DC
      :ok = EtherCAT.start(
        interface: "eth0",
        domains: [
          [id: :fast, period: 1]
        ],
        slaves: [
          nil,                                              # position 0 — no driver
          [name: :sensor, driver: MyApp.EL1809, config: %{},
           pdos: [channels: :fast]],                       # position 1
          [name: :valve,  driver: MyApp.EL2809, config: %{},
           pdos: [outputs: :fast]]                         # position 2
        ]
      )

      # 2. Subscribe to input change notifications (optional, before run)
      EtherCAT.subscribe(:sensor, :channels, self())

      # 3. Start domains, wire PDOs, activate cycling, advance slaves to :op
      :ok = EtherCAT.run()

      # 4. I/O
      EtherCAT.set_output(:valve, :outputs, 0xFFFF)

      receive do
        {:slave_input, :sensor, :channels, value} -> IO.inspect(value)
      end

  ## Shutdown

      EtherCAT.stop()

  ## Advanced

  Raw domain reads, SII identity, per-slave error codes, and domain stats are
  available on the sub-modules: `EtherCAT.Slave`, `EtherCAT.Domain`,
  `EtherCAT.Link`.
  """

  alias EtherCAT.{Domain, Master, Slave}

  # -- Bus lifecycle ---------------------------------------------------------

  @doc """
  Start the master: open `interface`, scan for slaves, initialise DC.

  Options:
    - `:interface` (required) — e.g. `"eth0"`
    - `:domains` — list of domain specs. Each is a keyword list with `:id`
      (atom) and `:period` (ms), plus optional `EtherCAT.Domain` options
    - `:slaves` — list of slave config entries. Each is either `nil` (station
      assigned, no driver) or a keyword list with `:name`, `:driver`, `:config`,
      and `:pdos` (`[pdo_name: domain_id]` pairs wired automatically on `run/0`)
    - `:base_station` — starting station address, default `0x1000`
    - `:dc_cycle_ns` — SYNC0 cycle time in ns for DC-capable slaves, default `1_000_000`
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: Master.start(opts)

  @doc "Stop the master: shut down all slaves, domains, and the link."
  @spec stop() :: :ok
  def stop, do: Master.stop()

  @doc "Return `[{name, station, pid}]` for all started slaves."
  @spec slaves() :: list()
  def slaves, do: Master.slaves()

  @doc "Return the link pid (escape hatch for raw `Link.transaction/2` calls)."
  @spec link() :: pid() | nil
  def link, do: Master.link()

  # -- One-shot activation ---------------------------------------------------

  @doc """
  Start all configured domains, wire declared PDOs, activate domain cycling,
  then advance all slaves to `:op`.

  Call this once after `start/1` and any `subscribe/3` calls. It is
  idempotent for already-running domains.
  """
  @spec run() :: :ok | {:error, term()}
  def run, do: Master.run()

  # -- Subscriptions ---------------------------------------------------------

  @doc """
  Subscribe `pid` to decoded input change notifications from a slave PDO.

  Messages arrive as `{:slave_input, slave_name, pdo_name, decoded_value}`.
  Must be called before `run/0` to guarantee no events are missed.
  """
  @spec subscribe(atom(), atom(), pid()) :: :ok
  def subscribe(slave_name, pdo_name, pid),
    do: Slave.subscribe(slave_name, pdo_name, pid)

  # -- Cyclic I/O ------------------------------------------------------------

  @doc """
  Encode `value` via the driver and write it to the domain output slot.

  Direct ETS write — no gen_statem hop.
  """
  @spec set_output(atom(), atom(), term()) :: :ok | {:error, term()}
  def set_output(slave_name, pdo_name, value),
    do: Slave.set_output(slave_name, pdo_name, value)

  @doc """
  Read the current raw input binary for a PDO directly from ETS.

  Returns `{:error, :not_ready}` until the first domain cycle completes.
  For decoded values, subscribe via `subscribe/3` instead.

  Direct ETS read — no gen_statem hop.
  """
  @spec read_input(Domain.domain_id(), atom(), atom()) ::
          {:ok, binary()} | {:error, :not_found | :not_ready}
  def read_input(domain_id, slave_name, pdo_name),
    do: Domain.read(domain_id, {slave_name, pdo_name})
end
