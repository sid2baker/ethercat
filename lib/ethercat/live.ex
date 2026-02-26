defmodule EtherCAT.Live do
  @moduledoc """
  IEx helpers for interactive hardware testing.

  Start a session:

      iex> use EtherCAT.Live
      iex> {:ok, link} = open("enp0s31f6")

  Discover slaves:

      iex> slave_count(link)
      2
      iex> scan(link)
      [%{position: 0, station: 0x1000, al_state: :preop}, ...]

  Read/write registers:

      iex> read_reg(link, 0x1000, 0x0130, 2)
      {:ok, <<4, 0>>}
      iex> write_reg(link, 0x1000, 0x0120, <<8, 0>>)
      :ok

  Broadcast:

      iex> brd(link, 0x0130, 2)
      {:ok, datagrams}

  Transition slaves:

      iex> transition(link, 0x1000, :op)
      :ok
  """

  alias EtherCAT.{Link, SII}
  alias EtherCAT.Link.Transaction

  defmacro __using__(_opts) do
    quote do
      alias EtherCAT.Link
      import EtherCAT.Live
      IO.puts("EtherCAT.Live loaded — open(\"eth0\") to start")
    end
  end

  @al_states %{
    0x01 => :init,
    0x02 => :preop,
    0x03 => :bootstrap,
    0x04 => :safeop,
    0x08 => :op
  }

  @al_requests %{
    init: 0x01,
    preop: 0x02,
    bootstrap: 0x03,
    safeop: 0x04,
    op: 0x08
  }

  @doc "Open a link to the given network interface."
  @spec open(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open(interface, opts \\ []) do
    Link.start_link(Keyword.merge([interface: interface], opts))
  end

  @doc "Close a link process."
  @spec close(pid()) :: :ok
  def close(link), do: :gen_statem.stop(link)

  @doc "Count slaves on the bus via broadcast read of address 0x0000."
  @spec slave_count(pid()) :: non_neg_integer()
  def slave_count(link) do
    {:ok, [%{wkc: wkc}]} = Link.transaction(link, &Transaction.brd(&1, 0x0000, 1))
    wkc
  end

  @doc """
  Scan the bus: assign station addresses and read AL state for each slave.

  Returns a list of maps with `:position`, `:station`, and `:al_state`.
  """
  @spec scan(pid(), non_neg_integer()) :: [map()]
  def scan(link, base_station \\ 0x1000) do
    count = slave_count(link)

    for pos <- 0..(count - 1) do
      station = base_station + pos

      {:ok, [_]} =
        Link.transaction(link, &Transaction.apwr(&1, pos, 0x0010, <<station::16-little>>))

      {:ok, [%{data: <<_::3, _::1, state::4, _::8>>}]} =
        Link.transaction(link, &Transaction.fprd(&1, station, 0x0130, 2))

      al = Map.get(@al_states, state, :unknown)
      %{position: pos, station: station, al_state: al}
    end
  end

  @doc "Read a register from a slave by configured station address."
  @spec read_reg(pid(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def read_reg(link, station, offset, length) do
    case Link.transaction(link, &Transaction.fprd(&1, station, offset, length)) do
      {:ok, [%{data: data, wkc: wkc}]} when wkc > 0 -> {:ok, data}
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err -> err
    end
  end

  @doc "Write a register on a slave by configured station address."
  @spec write_reg(pid(), non_neg_integer(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def write_reg(link, station, offset, data) do
    case Link.transaction(link, &Transaction.fpwr(&1, station, offset, data)) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 -> :ok
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err -> err
    end
  end

  @doc "Broadcast read. Returns `{:ok, data, wkc}`."
  @spec brd(pid(), non_neg_integer(), pos_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, term()}
  def brd(link, offset, length) do
    case Link.transaction(link, &Transaction.brd(&1, offset, length)) do
      {:ok, [%{data: data, wkc: wkc}]} -> {:ok, data, wkc}
      {:error, _} = err -> err
    end
  end

  @doc "Broadcast write. Returns `{:ok, wkc}`."
  @spec bwr(pid(), non_neg_integer(), binary()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def bwr(link, offset, data) do
    case Link.transaction(link, &Transaction.bwr(&1, offset, data)) do
      {:ok, [%{wkc: wkc}]} -> {:ok, wkc}
      {:error, _} = err -> err
    end
  end

  @doc """
  Transition a slave to the given AL state.

  Writes AL control register (0x0120) and polls AL status (0x0130)
  until the target state is reached or timeout.
  """
  @spec transition(pid(), non_neg_integer(), atom(), pos_integer()) :: :ok | {:error, term()}
  def transition(link, station, target, attempts \\ 200) do
    request = Map.fetch!(@al_requests, target)
    :ok = write_reg(link, station, 0x0120, <<request::16-little>>)
    wait_al(link, station, request, attempts)
  end

  @doc """
  Read the AL state of a slave.
  """
  @spec al_state(pid(), non_neg_integer()) :: {:ok, atom()} | {:error, term()}
  def al_state(link, station) do
    case read_reg(link, station, 0x0130, 2) do
      {:ok, <<_::3, _::1, state::4, _::8>>} ->
        {:ok, Map.get(@al_states, state, :unknown)}

      error ->
        error
    end
  end

  @doc """
  Read the ESC type and revision (register 0x0000, 1 byte each).
  """
  @spec esc_info(pid(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def esc_info(link, station) do
    with {:ok, <<esc_type>>} <- read_reg(link, station, 0x0000, 1),
         {:ok, <<revision>>} <- read_reg(link, station, 0x0001, 1),
         {:ok, <<build::16-little>>} <- read_reg(link, station, 0x0002, 2) do
      {:ok, %{type: esc_type, revision: revision, build: build}}
    end
  end

  @doc """
  Read `word_count` words from a slave's SII EEPROM.

      iex> read_eeprom(link, 0x1000, 0x00, 64)
      {:ok, <<...>>}
  """
  @spec read_eeprom(pid(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def read_eeprom(link, station, word_address \\ 0x00, word_count \\ 64) do
    SII.read(link, station, word_address, word_count)
  end

  @doc "Hex-dump a binary for quick inspection."
  @spec hexdump(binary()) :: :ok
  def hexdump(bin) do
    bin
    |> :binary.bin_to_list()
    |> Enum.chunk_every(16)
    |> Enum.with_index()
    |> Enum.each(fn {chunk, i} ->
      offset = String.pad_leading(Integer.to_string(i * 16, 16), 4, "0")

      hex =
        chunk
        |> Enum.map(&String.pad_leading(Integer.to_string(&1, 16), 2, "0"))
        |> Enum.chunk_every(2)
        |> Enum.map_join(" ", &Enum.join/1)

      ascii =
        chunk
        |> Enum.map(fn b -> if b in 0x20..0x7E, do: <<b>>, else: "." end)
        |> Enum.join()

      IO.puts("#{offset}  #{String.pad_trailing(hex, 39)}  #{ascii}")
    end)
  end

  # -- private ----------------------------------------------------------------

  defp wait_al(_link, _station, _request, 0), do: {:error, :al_timeout}

  defp wait_al(link, station, request, attempts) do
    case read_reg(link, station, 0x0130, 2) do
      {:ok, <<_::3, _::1, state::4, _::8>>} when state == request ->
        :ok

      {:ok, <<_::3, 1::1, _state::4, _::8>> = raw} ->
        {:error, {:al_error, raw}}

      _ ->
        Process.sleep(5)
        wait_al(link, station, request, attempts - 1)
    end
  end
end
