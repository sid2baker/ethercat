defmodule EtherCAT.Bus do
  @moduledoc """
  EtherCAT bus — frame transport layer.

  ## Public API

    * `start_link/1` — open a connection to the EtherCAT bus
    * `transaction/3` — real-time transaction with a staleness deadline
    * `transaction_queue/2` — reliable transaction that always queues to pending

  Commands are built using `EtherCAT.Bus.Transaction` and executed atomically.
  Results are returned as `[EtherCAT.Bus.Result.t()]` in the same order as
  the commands were added.

  ## Transport selection

  The transport is selected via the `:transport` option:

    - `:raw` (default) — AF_PACKET raw Ethernet, EtherType 0x88A4
    - `:udp` — UDP/IP encapsulation per spec §2.6

  ## Queuing behaviour

  When the bus is busy awaiting a frame response, incoming transactions are
  handled differently depending on which function was called:

    - **`transaction/3`** — the call is *postponed* in the gen_statem event
      queue. When the bus returns to `:idle` the deadline is checked: if
      `now - enqueued_at > timeout_us`, the call returns `{:error, :expired}`
      and the data is discarded. Use this for cyclic process data (LRW) and
      DC sync frames (ARMW) where stale data is worse than no data.
    - **`transaction_queue/2`** — always added to the `pending` queue and
      merged into the next combined frame. Never discarded. Use this for
      mailbox, CoE SDO, and configuration commands.

  ## Examples

      alias EtherCAT.Bus
      alias EtherCAT.Bus.Transaction

      # Raw Ethernet (single port)
      {:ok, bus} = Bus.start_link(interface: "eth0")

      # Raw Ethernet (redundant)
      {:ok, bus} = Bus.start_link(interface: "eth0", backup_interface: "eth1")

      # UDP/IP
      {:ok, bus} = Bus.start_link(transport: :udp, host: {192, 168, 1, 1})

      # Cyclic process data — 1 ms deadline
      {:ok, [io]} = Bus.transaction(bus, &Transaction.lrw(&1, {0, pdo_data}), 1_000)

      # Configuration/mailbox — always queued
      {:ok, [al]} = Bus.transaction_queue(bus, &Transaction.fprd(&1, 0x1001, Registers.al_status()))
  """

  alias EtherCAT.Bus.{Result, Transaction}
  alias EtherCAT.Telemetry

  @type server :: :gen_statem.server_ref()

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5000
    }
  end

  @doc """
  Start a bus process.

  ## Options

    - `:transport` — `:raw` (default) or `:udp`
    - `:interface` — network interface name, e.g. `"eth0"` (required for `:raw`)
    - `:backup_interface` — secondary interface for redundant raw mode
    - `:host` — destination IP tuple for UDP, e.g. `{192, 168, 1, 1}`
    - `:port` — UDP port (default: `34980` = `0x88A4`)
    - `:name` — optional registered name
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    transport_mod =
      case opts[:transport] do
        :udp -> EtherCAT.Bus.Transport.UdpSocket
        _ -> EtherCAT.Bus.Transport.RawSocket
      end

    impl =
      if opts[:backup_interface],
        do: EtherCAT.Bus.Redundant,
        else: EtherCAT.Bus.SinglePort

    opts = Keyword.put(opts, :transport_mod, transport_mod)

    gen_opts =
      case opts[:name] do
        nil -> []
        name -> [{:name, name}]
      end

    :gen_statem.start_link(impl, opts, gen_opts)
  end

  @doc """
  Execute a real-time transaction with a staleness deadline.

  If the bus is busy when this call arrives, it is *postponed* in the
  gen_statem event queue until the bus returns to `:idle`. At that point
  the deadline is checked: if `now - enqueued_at > timeout_us`, the call
  returns `{:error, :expired}` and the data is not sent.

  Use this for cyclic process data (LRW) and DC sync frames (ARMW) where
  sending stale data is worse than skipping a cycle. The default deadline
  of `1_000` µs (1 ms) suits a 1 kHz EtherCAT cycle.
  """
  @spec transaction(server(), (Transaction.t() -> Transaction.t()), pos_integer()) ::
          {:ok, [Result.t()]} | {:error, term()}
  def transaction(bus, fun, timeout_us \\ 1_000) when is_function(fun, 1) do
    %Transaction{datagrams: datagrams} = fun.(Transaction.new())
    enqueued_at = System.monotonic_time(:microsecond)

    do_call(bus, {:transact, datagrams, enqueued_at, timeout_us}, length(datagrams))
  end

  @doc """
  Execute a reliable transaction that always queues to pending.

  If the bus is busy, the transaction is added to the pending queue and
  merged into the next combined frame — it is never discarded. Use this
  for mailbox, CoE SDO, and configuration commands where delivery matters
  more than timing.
  """
  @spec transaction_queue(server(), (Transaction.t() -> Transaction.t())) ::
          {:ok, [Result.t()]} | {:error, term()}
  def transaction_queue(bus, fun) when is_function(fun, 1) do
    %Transaction{datagrams: datagrams} = fun.(Transaction.new())

    do_call(bus, {:transact_queue, datagrams}, length(datagrams))
  end

  defp do_call(bus, msg, datagram_count) do
    meta = %{datagram_count: datagram_count}

    Telemetry.span([:ethercat, :bus, :transact], meta, fn ->
      result =
        try do
          :gen_statem.call(bus, msg, 150)
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
          :exit, reason -> {:error, reason}
        end

      case result do
        {:ok, response_datagrams} ->
          results =
            Enum.map(response_datagrams, fn dg ->
              %Result{
                data: dg.data,
                wkc: dg.wkc,
                circular: dg.circular,
                irq: <<dg.irq::little-unsigned-16>>
              }
            end)

          stop_meta = %{
            datagram_count: length(results),
            total_wkc: Enum.sum(Enum.map(results, & &1.wkc))
          }

          {{:ok, results}, stop_meta}

        {:error, _} = err ->
          {err, meta}
      end
    end)
  end
end
