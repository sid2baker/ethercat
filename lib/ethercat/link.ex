defmodule EtherCAT.Link do
  @moduledoc """
  EtherCAT data link layer — raw Ethernet frame transport.

  Provides `start_link/1` and `transact/3`. The implementation is chosen
  at start time based on whether `:backup_interface` is provided:

    - Single interface → `EtherCAT.Link.Normal`
    - Two interfaces   → `EtherCAT.Link.Redundant`

  Both are `:gen_statem` processes. Concurrent `transact/3` calls are
  serialized via postpone — callers block until their turn.

  ## Examples

      {:ok, link} = EtherCAT.Link.start_link(interface: "eth0")

      {:ok, [response]} = EtherCAT.Link.transact(link, [
        EtherCAT.Command.brd(0x0130, 2)
      ])
  """

  @type datagrams :: [EtherCAT.Datagram.t()]

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

  @doc """
  Send datagrams as a single EtherCAT frame and wait for the response.

  Returns `{:ok, response_datagrams}` or `{:error, reason}`.
  Concurrent calls are queued automatically.

  Emits `[:ethercat, :link, :transact, :start | :stop | :exception]`
  telemetry events.
  """
  @spec transact(:gen_statem.server_ref(), datagrams(), timeout()) ::
          {:ok, datagrams()} | {:error, term()}
  def transact(link, datagrams, timeout \\ 50) do
    meta = %{datagram_count: length(datagrams)}

    EtherCAT.Telemetry.span([:ethercat, :link, :transact], meta, fn ->
      result = :gen_statem.call(link, {:transact, datagrams}, timeout)

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
