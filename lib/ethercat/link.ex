defmodule EtherCAT.Link do
  @moduledoc """
  EtherCAT data link layer — raw Ethernet frame transport.

  Provides `start_link/1` and the full set of EtherCAT commands as a
  simple call-and-return API. The underlying framing, datagram encoding,
  and socket I/O are implementation details.

  The implementation is chosen at start time based on options:
    - Single interface → `EtherCAT.Link.Normal`
    - Two interfaces   → `EtherCAT.Link.Redundant`

  ## Addressing modes

  | Functions              | Mode                   | Address           |
  |------------------------|------------------------|-------------------|
  | `fprd/4`, `fpwr/4`...  | Configured station     | 16-bit address    |
  | `aprd/4`, `apwr/4`...  | Auto-increment         | 0-based position  |
  | `brd/3`, `bwr/3`...    | Broadcast              | all slaves        |
  | `lrd/3`, `lwr/3`...    | Logical (FMMU-mapped)  | 32-bit address    |

  ## Examples

      {:ok, link} = EtherCAT.Link.start_link(interface: "eth0")

      # Read AL status from slave at station 0x1001
      {:ok, status} = EtherCAT.Link.fprd(link, 0x1001, 0x0130, 2)

      # Write AL control
      :ok = EtherCAT.Link.fpwr(link, 0x1001, 0x0120, <<0x08, 0x00>>)

      # Broadcast read — returns data + WKC (= slave count)
      {:ok, _data, slave_count} = EtherCAT.Link.brd(link, 0x0000, 1)

      # Logical read/write (process image)
      {:ok, inputs} = EtherCAT.Link.lrw(link, 0x0000, <<0xFF, 0xFF, 0, 0>>)
  """

  alias EtherCAT.Link.Command
  alias EtherCAT.Telemetry

  @type server :: :gen_statem.server_ref()

  @doc """
  Start a link process.

  ## Options

    - `:interface` (required) — primary network interface, e.g. `"eth0"`
    - `:backup_interface` — secondary interface for redundant mode
    - `:name` — optional registered name
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    impl =
      if opts[:backup_interface],
        do: EtherCAT.Link.Redundant,
        else: EtherCAT.Link.Normal

    gen_opts =
      case opts[:name] do
        nil -> []
        name -> [{:name, name}]
      end

    :gen_statem.start_link(impl, opts, gen_opts)
  end

  # ---------------------------------------------------------------------------
  # Configured station address (FPRD / FPWR / FPRW / FRMW)
  # ---------------------------------------------------------------------------

  @doc "Configured address read. Returns `{:ok, data}` or `{:error, reason}`."
  @spec fprd(server(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def fprd(link, station, offset, length) do
    case transact(link, [Command.fprd(station, offset, length)]) do
      {:ok, [%{data: data}]} -> {:ok, data}
      {:ok, [%{wkc: 0}]}    -> {:error, :no_response}
      {:error, _} = err      -> err
    end
  end

  @doc "Configured address write. Returns `:ok` or `{:error, reason}`."
  @spec fpwr(server(), non_neg_integer(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def fpwr(link, station, offset, data) do
    case transact(link, [Command.fpwr(station, offset, data)]) do
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:ok, _}           -> :ok
      {:error, _} = err  -> err
    end
  end

  @doc "Configured address read/write. Returns `{:ok, data}` or `{:error, reason}`."
  @spec fprw(server(), non_neg_integer(), non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def fprw(link, station, offset, data) do
    case transact(link, [Command.fprw(station, offset, data)]) do
      {:ok, [%{data: d}]} -> {:ok, d}
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err   -> err
    end
  end

  @doc """
  Configured address read multiple write (FRMW).

  The addressed slave reads; all others write the returned value.
  Returns `{:ok, data}` or `{:error, reason}`.
  """
  @spec frmw(server(), non_neg_integer(), non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def frmw(link, station, offset, data) do
    case transact(link, [Command.frmw(station, offset, data)]) do
      {:ok, [%{data: d}]} -> {:ok, d}
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err   -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Auto-increment address (APRD / APWR / APRW / ARMW)
  # ---------------------------------------------------------------------------

  @doc "Auto-increment read. `position` is 0-based physical position."
  @spec aprd(server(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def aprd(link, position, offset, length) do
    case transact(link, [Command.aprd(position, offset, length)]) do
      {:ok, [%{data: data}]} -> {:ok, data}
      {:ok, [%{wkc: 0}]}    -> {:error, :no_response}
      {:error, _} = err      -> err
    end
  end

  @doc "Auto-increment write."
  @spec apwr(server(), non_neg_integer(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def apwr(link, position, offset, data) do
    case transact(link, [Command.apwr(position, offset, data)]) do
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:ok, _}           -> :ok
      {:error, _} = err  -> err
    end
  end

  @doc "Auto-increment read/write."
  @spec aprw(server(), non_neg_integer(), non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def aprw(link, position, offset, data) do
    case transact(link, [Command.aprw(position, offset, data)]) do
      {:ok, [%{data: d}]} -> {:ok, d}
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err   -> err
    end
  end

  @doc """
  Auto-increment read multiple write (ARMW).

  The slave at `position` reads; all others write the returned value.
  Used for distributed clock synchronisation.
  """
  @spec armw(server(), non_neg_integer(), non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def armw(link, position, offset, data) do
    case transact(link, [Command.armw(position, offset, data)]) do
      {:ok, [%{data: d}]} -> {:ok, d}
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err   -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Broadcast (BRD / BWR / BRW)
  # WKC = number of slaves that responded — always returned.
  # ---------------------------------------------------------------------------

  @doc "Broadcast read. Returns `{:ok, data, wkc}` where `wkc` is the slave count."
  @spec brd(server(), non_neg_integer(), pos_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, term()}
  def brd(link, offset, length) do
    case transact(link, [Command.brd(offset, length)]) do
      {:ok, [%{data: data, wkc: wkc}]} -> {:ok, data, wkc}
      {:error, _} = err                -> err
    end
  end

  @doc "Broadcast write. Returns `{:ok, wkc}` where `wkc` is the slave count."
  @spec bwr(server(), non_neg_integer(), binary()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def bwr(link, offset, data) do
    case transact(link, [Command.bwr(offset, data)]) do
      {:ok, [%{wkc: wkc}]} -> {:ok, wkc}
      {:error, _} = err     -> err
    end
  end

  @doc "Broadcast read/write. Returns `{:ok, data, wkc}` where `wkc` is the slave count."
  @spec brw(server(), non_neg_integer(), binary()) ::
          {:ok, binary(), non_neg_integer()} | {:error, term()}
  def brw(link, offset, data) do
    case transact(link, [Command.brw(offset, data)]) do
      {:ok, [%{data: d, wkc: wkc}]} -> {:ok, d, wkc}
      {:error, _} = err              -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Logical memory (LRD / LWR / LRW) — FMMU-mapped process image
  # ---------------------------------------------------------------------------

  @doc "Logical memory read."
  @spec lrd(server(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def lrd(link, addr, length) do
    case transact(link, [Command.lrd(addr, length)]) do
      {:ok, [%{data: data}]} -> {:ok, data}
      {:ok, [%{wkc: 0}]}    -> {:error, :no_response}
      {:error, _} = err      -> err
    end
  end

  @doc "Logical memory write."
  @spec lwr(server(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def lwr(link, addr, data) do
    case transact(link, [Command.lwr(addr, data)]) do
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:ok, _}           -> :ok
      {:error, _} = err  -> err
    end
  end

  @doc "Logical memory read/write — atomic output write + input read over FMMU."
  @spec lrw(server(), non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def lrw(link, addr, data) do
    case transact(link, [Command.lrw(addr, data)]) do
      {:ok, [%{data: d}]} -> {:ok, d}
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err   -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Low-level escape hatch — send multiple datagrams in one frame
  # ---------------------------------------------------------------------------

  @doc """
  Send a list of datagrams as a single EtherCAT frame and return the responses.

  Use this when you need to batch multiple independent commands into one
  round-trip (e.g. reading AL status from all slaves simultaneously).
  For single commands, prefer the named functions above.
  """
  @spec transact(server(), list()) :: {:ok, list()} | {:error, term()}
  def transact(link, datagrams) do
    meta = %{datagram_count: length(datagrams)}

    Telemetry.span([:ethercat, :link, :transact], meta, fn ->
      result = :gen_statem.call(link, {:transact, datagrams}, 50)

      stop_meta =
        case result do
          {:ok, dgs} ->
            %{datagram_count: length(dgs), total_wkc: Enum.sum(Enum.map(dgs, & &1.wkc))}

          {:error, _} ->
            meta
        end

      {result, stop_meta}
    end)
  end
end
