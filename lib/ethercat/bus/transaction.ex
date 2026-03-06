defmodule EtherCAT.Bus.Transaction do
  @moduledoc """
  Builder for ordered EtherCAT datagram transactions.

  `Transaction` is the caller-side unit of atomic intent. The bus may coalesce
  multiple reliable transactions into one frame, but each transaction still
  receives its own ordered list of results.

  Transactions may be built incrementally:

      Transaction.new()
      |> Transaction.fpwr(0x1001, Registers.al_control(0x08))
      |> Transaction.fprd(0x1001, Registers.al_status())

  Or created directly for a single datagram:

      Transaction.fprd(0x1001, Registers.al_status())
      Transaction.lrw({0x0000, image})
  """

  alias EtherCAT.Bus.Datagram

  @nop 0
  @aprd 1
  @apwr 2
  @aprw 3
  @fprd 4
  @fpwr 5
  @fprw 6
  @brd 7
  @bwr 8
  @brw 9
  @lrd 10
  @lwr 11
  @lrw 12
  @armw 13
  @frmw 14

  @opaque t :: %__MODULE__{datagrams_rev: [Datagram.t()]}

  defstruct datagrams_rev: []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec datagrams(t()) :: [Datagram.t()]
  def datagrams(%__MODULE__{datagrams_rev: datagrams_rev}), do: Enum.reverse(datagrams_rev)

  @doc "Configured address read. `reg` is `{offset, length}` from `Registers`."
  @spec fprd(t(), non_neg_integer(), {non_neg_integer(), pos_integer()}) :: t()
  def fprd(%__MODULE__{} = tx, station, {offset, length}) when is_integer(length) do
    append(tx, fixed_read(@fprd, station, offset, length))
  end

  @spec fprd(non_neg_integer(), {non_neg_integer(), pos_integer()}) :: t()
  def fprd(station, reg), do: new() |> fprd(station, reg)

  @doc "Configured address write. `reg` is `{offset, data}` from `Registers`."
  @spec fpwr(t(), non_neg_integer(), {non_neg_integer(), binary()}) :: t()
  def fpwr(%__MODULE__{} = tx, station, {offset, data}) when is_binary(data) do
    append(tx, fixed_write(@fpwr, station, offset, data))
  end

  @spec fpwr(non_neg_integer(), {non_neg_integer(), binary()}) :: t()
  def fpwr(station, reg), do: new() |> fpwr(station, reg)

  @doc "Configured address read/write. `reg` is `{offset, data}`."
  @spec fprw(t(), non_neg_integer(), {non_neg_integer(), binary()}) :: t()
  def fprw(%__MODULE__{} = tx, station, {offset, data}) when is_binary(data) do
    append(tx, fixed_write(@fprw, station, offset, data))
  end

  @spec fprw(non_neg_integer(), {non_neg_integer(), binary()}) :: t()
  def fprw(station, reg), do: new() |> fprw(station, reg)

  @doc "Configured address read multiple write (FRMW). `reg` is `{offset, data}`."
  @spec frmw(t(), non_neg_integer(), {non_neg_integer(), binary()}) :: t()
  def frmw(%__MODULE__{} = tx, station, {offset, data}) when is_binary(data) do
    append(tx, fixed_write(@frmw, station, offset, data))
  end

  @spec frmw(non_neg_integer(), {non_neg_integer(), binary()}) :: t()
  def frmw(station, reg), do: new() |> frmw(station, reg)

  @doc "Auto-increment read. `position` is 0-based. `reg` is `{offset, length}`."
  @spec aprd(t(), non_neg_integer(), {non_neg_integer(), pos_integer()}) :: t()
  def aprd(%__MODULE__{} = tx, position, {offset, length}) when is_integer(length) do
    append(tx, auto_read(@aprd, position, offset, length))
  end

  @spec aprd(non_neg_integer(), {non_neg_integer(), pos_integer()}) :: t()
  def aprd(position, reg), do: new() |> aprd(position, reg)

  @doc "Auto-increment write. `reg` is `{offset, data}`."
  @spec apwr(t(), non_neg_integer(), {non_neg_integer(), binary()}) :: t()
  def apwr(%__MODULE__{} = tx, position, {offset, data}) when is_binary(data) do
    append(tx, auto_write(@apwr, position, offset, data))
  end

  @spec apwr(non_neg_integer(), {non_neg_integer(), binary()}) :: t()
  def apwr(position, reg), do: new() |> apwr(position, reg)

  @doc "Auto-increment read/write. `reg` is `{offset, data}`."
  @spec aprw(t(), non_neg_integer(), {non_neg_integer(), binary()}) :: t()
  def aprw(%__MODULE__{} = tx, position, {offset, data}) when is_binary(data) do
    append(tx, auto_write(@aprw, position, offset, data))
  end

  @spec aprw(non_neg_integer(), {non_neg_integer(), binary()}) :: t()
  def aprw(position, reg), do: new() |> aprw(position, reg)

  @doc """
  Auto-increment read multiple write (ARMW). `reg` is `{offset, length_or_data}`.
  When `length` is an integer, a zero-filled binary of that size is used as the
  write payload.
  """
  @spec armw(t(), non_neg_integer(), {non_neg_integer(), pos_integer() | binary()}) :: t()
  def armw(%__MODULE__{} = tx, position, {offset, length}) when is_integer(length) do
    append(tx, auto_write(@armw, position, offset, :binary.copy(<<0>>, length)))
  end

  def armw(%__MODULE__{} = tx, position, {offset, data}) when is_binary(data) do
    append(tx, auto_write(@armw, position, offset, data))
  end

  @spec armw(non_neg_integer(), {non_neg_integer(), pos_integer() | binary()}) :: t()
  def armw(position, reg), do: new() |> armw(position, reg)

  @doc "Broadcast read. `reg` is `{offset, length}`."
  @spec brd(t(), {non_neg_integer(), pos_integer()}) :: t()
  def brd(%__MODULE__{} = tx, {offset, length}) when is_integer(length) do
    append(tx, broadcast_read(@brd, offset, length))
  end

  @spec brd({non_neg_integer(), pos_integer()}) :: t()
  def brd(reg), do: new() |> brd(reg)

  @doc "Broadcast write. `reg` is `{offset, data}`."
  @spec bwr(t(), {non_neg_integer(), binary()}) :: t()
  def bwr(%__MODULE__{} = tx, {offset, data}) when is_binary(data) do
    append(tx, broadcast_write(@bwr, offset, data))
  end

  @spec bwr({non_neg_integer(), binary()}) :: t()
  def bwr(reg), do: new() |> bwr(reg)

  @doc "Broadcast read/write. `reg` is `{offset, data}`."
  @spec brw(t(), {non_neg_integer(), binary()}) :: t()
  def brw(%__MODULE__{} = tx, {offset, data}) when is_binary(data) do
    append(tx, broadcast_write(@brw, offset, data))
  end

  @spec brw({non_neg_integer(), binary()}) :: t()
  def brw(reg), do: new() |> brw(reg)

  @doc "Logical memory read. `addr_len` is `{addr, length}`."
  @spec lrd(t(), {non_neg_integer(), pos_integer()}) :: t()
  def lrd(%__MODULE__{} = tx, {addr, length}) when is_integer(length) do
    append(tx, logical_read(@lrd, addr, length))
  end

  @spec lrd({non_neg_integer(), pos_integer()}) :: t()
  def lrd(reg), do: new() |> lrd(reg)

  @doc "Logical memory write. `addr_data` is `{addr, data}`."
  @spec lwr(t(), {non_neg_integer(), binary()}) :: t()
  def lwr(%__MODULE__{} = tx, {addr, data}) when is_binary(data) do
    append(tx, logical_write(@lwr, addr, data))
  end

  @spec lwr({non_neg_integer(), binary()}) :: t()
  def lwr(reg), do: new() |> lwr(reg)

  @doc "Logical memory read/write. `addr_data` is `{addr, data}`."
  @spec lrw(t(), {non_neg_integer(), binary()}) :: t()
  def lrw(%__MODULE__{} = tx, {addr, data}) when is_binary(data) do
    append(tx, logical_write(@lrw, addr, data))
  end

  @spec lrw({non_neg_integer(), binary()}) :: t()
  def lrw(reg), do: new() |> lrw(reg)

  @doc false
  @spec nop() :: t()
  def nop, do: %__MODULE__{datagrams_rev: [%Datagram{cmd: @nop}]}

  defp append(%__MODULE__{datagrams_rev: datagrams_rev} = tx, datagram) do
    %{tx | datagrams_rev: [datagram | datagrams_rev]}
  end

  defp auto_read(cmd, position, offset, length) do
    %Datagram{cmd: cmd, address: position_address(-position, offset), data: zeroes(length)}
  end

  defp auto_write(cmd, position, offset, data) do
    %Datagram{cmd: cmd, address: position_address(-position, offset), data: data}
  end

  defp fixed_read(cmd, station, offset, length) do
    %Datagram{cmd: cmd, address: station_address(station, offset), data: zeroes(length)}
  end

  defp fixed_write(cmd, station, offset, data) do
    %Datagram{cmd: cmd, address: station_address(station, offset), data: data}
  end

  defp broadcast_read(cmd, offset, length) do
    %Datagram{cmd: cmd, address: position_address(0, offset), data: zeroes(length)}
  end

  defp broadcast_write(cmd, offset, data) do
    %Datagram{cmd: cmd, address: position_address(0, offset), data: data}
  end

  defp logical_read(cmd, logical_address, length) do
    %Datagram{cmd: cmd, address: <<logical_address::little-unsigned-32>>, data: zeroes(length)}
  end

  defp logical_write(cmd, logical_address, data) do
    %Datagram{cmd: cmd, address: <<logical_address::little-unsigned-32>>, data: data}
  end

  defp zeroes(length), do: :binary.copy(<<0>>, length)

  defp position_address(position, offset),
    do: <<position::little-signed-16, offset::little-unsigned-16>>

  defp station_address(station, offset),
    do: <<station::little-unsigned-16, offset::little-unsigned-16>>
end
