defmodule EtherCAT.Link do
  @moduledoc """
  EtherCAT data link layer — raw Ethernet frame transport.

  ## Public API

    * `start_link/1` — open a link to one or two network interfaces
    * `transaction/2` — execute batched EtherCAT commands in a single frame

  Commands are built using `EtherCAT.Link.Transaction` and executed
  atomically. Results are returned as `[EtherCAT.Link.Result.t()]`
  in the same order as the commands were added.

  ## Examples

      alias EtherCAT.Link
      alias EtherCAT.Link.Transaction

      {:ok, link} = Link.start_link(interface: "eth0")

      # Single read
      {:ok, [%{data: <<status::16-little>>, wkc: 1}]} =
        Link.transaction(link, &Transaction.fprd(&1, 0x1001, Registers.al_status()))

      # Batched — read AL status + exchange process image
      {:ok, [al, io]} =
        Link.transaction(link, fn tx ->
          tx
          |> Transaction.fprd(0x1001, Registers.al_status())
          |> Transaction.lrw({0x0000, <<0, 0, 0, 0>>})
        end)
  """

  alias EtherCAT.Link.{Result, Transaction}
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
        else: EtherCAT.Link.SinglePort

    gen_opts =
      case opts[:name] do
        nil -> []
        name -> [{:name, name}]
      end

    :gen_statem.start_link(impl, opts, gen_opts)
  end

  @doc """
  Execute a transaction — build commands, send as one frame, return results.

  The given function receives an empty `Transaction.t()` and must return
  a `Transaction.t()` with one or more commands added. Results are returned
  in the same order as the commands were added.

  ## Examples

      # Single command
      {:ok, [%{data: data, wkc: 1}]} =
        Link.transaction(link, &Transaction.fprd(&1, 0x1001, Registers.al_status()))

      # Batched commands
      {:ok, [res1, res2]} =
        Link.transaction(link, fn tx ->
          tx
          |> Transaction.fprd(0x1001, Registers.al_status())
          |> Transaction.lrw({0x0000, <<0, 0, 0, 0>>})
        end)
  """
  @spec transaction(server(), (Transaction.t() -> Transaction.t())) ::
          {:ok, [Result.t()]} | {:error, term()}
  def transaction(link, fun) when is_function(fun, 1) do
    %Transaction{datagrams: datagrams} = fun.(Transaction.new())

    meta = %{datagram_count: length(datagrams)}

    Telemetry.span([:ethercat, :link, :transact], meta, fn ->
      result =
        try do
          :gen_statem.call(link, {:transact, datagrams}, 1_000)
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
