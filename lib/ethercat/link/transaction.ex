defmodule EtherCAT.Link.Transaction do
  @moduledoc """
  Builder for batched EtherCAT commands.

  Used inside `EtherCAT.Link.transaction/2`:

      Link.transaction(link, fn tx ->
        tx
        |> Transaction.fprd(0x1001, Registers.al_status())
        |> Transaction.lrw(0x0000, <<0, 0, 0, 0>>)
      end)

  Every command that accesses a physical register accepts a `{offset, length_or_data}`
  tuple so callers can pass register descriptors from `EtherCAT.Slave.Registers` directly:

      Transaction.fprd(tx, station, Registers.al_status())
      Transaction.fpwr(tx, station, Registers.al_control(0x08))

  For `armw`, a tuple with an integer length produces a zero-filled write
  payload (the ARMW data field is overwritten by the reference clock anyway).

  Results are returned in the same order as commands are added.

  ## Command families

  | Functions                               | Mode               | Address           |
  |-----------------------------------------|--------------------|-------------------|
  | `fprd/3`, `fpwr/3`, `fprw/3`, `frmw/3` | Configured station  | 16-bit address    |
  | `aprd/3`, `apwr/3`, `aprw/3`, `armw/3` | Auto-increment      | 0-based position  |
  | `brd/2`, `bwr/2`, `brw/2`              | Broadcast           | all slaves        |
  | `lrd/2`, `lwr/2`, `lrw/2`              | Logical (FMMU)      | 32-bit address    |
  """

  alias EtherCAT.Link.Command

  @opaque t :: %__MODULE__{datagrams: [EtherCAT.Link.Datagram.t()]}

  defstruct datagrams: []

  @doc false
  def new, do: %__MODULE__{}

  # -- Configured station address (FPxx) --------------------------------------

  @doc "Configured address read. `reg` is `{offset, length}` from `Registers`."
  @spec fprd(t(), non_neg_integer(), {non_neg_integer(), pos_integer()}) :: t()
  def fprd(%__MODULE__{} = tx, station, {offset, length}) when is_integer(length),
    do: append(tx, Command.fprd(station, offset, length))

  @doc "Configured address write. `reg` is `{offset, data}` from `Registers`."
  @spec fpwr(t(), non_neg_integer(), {non_neg_integer(), binary()}) :: t()
  def fpwr(%__MODULE__{} = tx, station, {offset, data}) when is_binary(data),
    do: append(tx, Command.fpwr(station, offset, data))

  @doc "Configured address read/write. `reg` is `{offset, data}`."
  @spec fprw(t(), non_neg_integer(), {non_neg_integer(), binary()}) :: t()
  def fprw(%__MODULE__{} = tx, station, {offset, data}) when is_binary(data),
    do: append(tx, Command.fprw(station, offset, data))

  @doc "Configured address read multiple write (FRMW). `reg` is `{offset, data}`."
  @spec frmw(t(), non_neg_integer(), {non_neg_integer(), binary()}) :: t()
  def frmw(%__MODULE__{} = tx, station, {offset, data}) when is_binary(data),
    do: append(tx, Command.frmw(station, offset, data))

  # -- Auto-increment address (APxx) ------------------------------------------

  @doc "Auto-increment read. `position` is 0-based. `reg` is `{offset, length}`."
  @spec aprd(t(), non_neg_integer(), {non_neg_integer(), pos_integer()}) :: t()
  def aprd(%__MODULE__{} = tx, position, {offset, length}) when is_integer(length),
    do: append(tx, Command.aprd(position, offset, length))

  @doc "Auto-increment write. `reg` is `{offset, data}`."
  @spec apwr(t(), non_neg_integer(), {non_neg_integer(), binary()}) :: t()
  def apwr(%__MODULE__{} = tx, position, {offset, data}) when is_binary(data),
    do: append(tx, Command.apwr(position, offset, data))

  @doc "Auto-increment read/write. `reg` is `{offset, data}`."
  @spec aprw(t(), non_neg_integer(), {non_neg_integer(), binary()}) :: t()
  def aprw(%__MODULE__{} = tx, position, {offset, data}) when is_binary(data),
    do: append(tx, Command.aprw(position, offset, data))

  @doc """
  Auto-increment read multiple write (ARMW). `reg` is `{offset, length_or_data}`.
  When `length` is an integer, a zero-filled binary of that size is used as the
  write payload (the reference clock overwrites it anyway).
  """
  @spec armw(t(), non_neg_integer(), {non_neg_integer(), pos_integer() | binary()}) :: t()
  def armw(%__MODULE__{} = tx, position, {offset, length}) when is_integer(length),
    do: append(tx, Command.armw(position, offset, :binary.copy(<<0>>, length)))

  def armw(%__MODULE__{} = tx, position, {offset, data}) when is_binary(data),
    do: append(tx, Command.armw(position, offset, data))

  # -- Broadcast (Bxx) --------------------------------------------------------

  @doc "Broadcast read. `reg` is `{offset, length}`."
  @spec brd(t(), {non_neg_integer(), pos_integer()}) :: t()
  def brd(%__MODULE__{} = tx, {offset, length}) when is_integer(length),
    do: append(tx, Command.brd(offset, length))

  @doc "Broadcast write. `reg` is `{offset, data}`."
  @spec bwr(t(), {non_neg_integer(), binary()}) :: t()
  def bwr(%__MODULE__{} = tx, {offset, data}) when is_binary(data),
    do: append(tx, Command.bwr(offset, data))

  @doc "Broadcast read/write. `reg` is `{offset, data}`."
  @spec brw(t(), {non_neg_integer(), binary()}) :: t()
  def brw(%__MODULE__{} = tx, {offset, data}) when is_binary(data),
    do: append(tx, Command.brw(offset, data))

  # -- Logical memory (Lxx) ---------------------------------------------------

  @doc "Logical memory read. `addr_len` is `{addr, length}`."
  @spec lrd(t(), {non_neg_integer(), pos_integer()}) :: t()
  def lrd(%__MODULE__{} = tx, {addr, length}) when is_integer(length),
    do: append(tx, Command.lrd(addr, length))

  @doc "Logical memory write. `addr_data` is `{addr, data}`."
  @spec lwr(t(), {non_neg_integer(), binary()}) :: t()
  def lwr(%__MODULE__{} = tx, {addr, data}) when is_binary(data),
    do: append(tx, Command.lwr(addr, data))

  @doc "Logical memory read/write. `addr_data` is `{addr, data}`."
  @spec lrw(t(), {non_neg_integer(), binary()}) :: t()
  def lrw(%__MODULE__{} = tx, {addr, data}) when is_binary(data),
    do: append(tx, Command.lrw(addr, data))

  # -- internal ---------------------------------------------------------------

  defp append(%__MODULE__{datagrams: dgs} = tx, datagram),
    do: %{tx | datagrams: dgs ++ [datagram]}
end
