defmodule EtherCAT.Link.Transaction do
  @moduledoc """
  Builder for batched EtherCAT commands.

  Used inside `EtherCAT.Link.transaction/2`:

      Link.transaction(link, fn tx ->
        tx
        |> Transaction.fprd(0x1001, 0x0130, 2)
        |> Transaction.lrw(0x0000, <<0, 0, 0, 0>>)
      end)

  Results are returned in the same order as commands are added.

  ## Command families

  | Functions                        | Mode               | Address           |
  |----------------------------------|---------------------|-------------------|
  | `fprd/4`, `fpwr/4`, `fprw/4`, `frmw/4` | Configured station  | 16-bit address    |
  | `aprd/4`, `apwr/4`, `aprw/4`, `armw/4` | Auto-increment      | 0-based position  |
  | `brd/3`, `bwr/3`, `brw/3`       | Broadcast           | all slaves        |
  | `lrd/3`, `lwr/3`, `lrw/3`       | Logical (FMMU)      | 32-bit address    |
  """

  alias EtherCAT.Link.Command

  @opaque t :: %__MODULE__{datagrams: [EtherCAT.Link.Datagram.t()]}

  defstruct datagrams: []

  @doc false
  def new, do: %__MODULE__{}

  # -- Configured station address (FPxx) --------------------------------------

  @doc "Configured address read."
  @spec fprd(t(), non_neg_integer(), non_neg_integer(), pos_integer()) :: t()
  def fprd(%__MODULE__{} = tx, station, offset, length),
    do: append(tx, Command.fprd(station, offset, length))

  @doc "Configured address write."
  @spec fpwr(t(), non_neg_integer(), non_neg_integer(), binary()) :: t()
  def fpwr(%__MODULE__{} = tx, station, offset, data),
    do: append(tx, Command.fpwr(station, offset, data))

  @doc "Configured address read/write."
  @spec fprw(t(), non_neg_integer(), non_neg_integer(), binary()) :: t()
  def fprw(%__MODULE__{} = tx, station, offset, data),
    do: append(tx, Command.fprw(station, offset, data))

  @doc "Configured address read multiple write (FRMW)."
  @spec frmw(t(), non_neg_integer(), non_neg_integer(), binary()) :: t()
  def frmw(%__MODULE__{} = tx, station, offset, data),
    do: append(tx, Command.frmw(station, offset, data))

  # -- Auto-increment address (APxx) ------------------------------------------

  @doc "Auto-increment read. `position` is 0-based physical position."
  @spec aprd(t(), non_neg_integer(), non_neg_integer(), pos_integer()) :: t()
  def aprd(%__MODULE__{} = tx, position, offset, length),
    do: append(tx, Command.aprd(position, offset, length))

  @doc "Auto-increment write."
  @spec apwr(t(), non_neg_integer(), non_neg_integer(), binary()) :: t()
  def apwr(%__MODULE__{} = tx, position, offset, data),
    do: append(tx, Command.apwr(position, offset, data))

  @doc "Auto-increment read/write."
  @spec aprw(t(), non_neg_integer(), non_neg_integer(), binary()) :: t()
  def aprw(%__MODULE__{} = tx, position, offset, data),
    do: append(tx, Command.aprw(position, offset, data))

  @doc "Auto-increment read multiple write (ARMW)."
  @spec armw(t(), non_neg_integer(), non_neg_integer(), binary()) :: t()
  def armw(%__MODULE__{} = tx, position, offset, data),
    do: append(tx, Command.armw(position, offset, data))

  # -- Broadcast (Bxx) --------------------------------------------------------

  @doc "Broadcast read."
  @spec brd(t(), non_neg_integer(), pos_integer()) :: t()
  def brd(%__MODULE__{} = tx, offset, length),
    do: append(tx, Command.brd(offset, length))

  @doc "Broadcast write."
  @spec bwr(t(), non_neg_integer(), binary()) :: t()
  def bwr(%__MODULE__{} = tx, offset, data),
    do: append(tx, Command.bwr(offset, data))

  @doc "Broadcast read/write."
  @spec brw(t(), non_neg_integer(), binary()) :: t()
  def brw(%__MODULE__{} = tx, offset, data),
    do: append(tx, Command.brw(offset, data))

  # -- Logical memory (Lxx) ---------------------------------------------------

  @doc "Logical memory read."
  @spec lrd(t(), non_neg_integer(), pos_integer()) :: t()
  def lrd(%__MODULE__{} = tx, addr, length),
    do: append(tx, Command.lrd(addr, length))

  @doc "Logical memory write."
  @spec lwr(t(), non_neg_integer(), binary()) :: t()
  def lwr(%__MODULE__{} = tx, addr, data),
    do: append(tx, Command.lwr(addr, data))

  @doc "Logical memory read/write."
  @spec lrw(t(), non_neg_integer(), binary()) :: t()
  def lrw(%__MODULE__{} = tx, addr, data),
    do: append(tx, Command.lrw(addr, data))

  # -- internal ---------------------------------------------------------------

  defp append(%__MODULE__{datagrams: dgs} = tx, datagram),
    do: %{tx | datagrams: dgs ++ [datagram]}
end
