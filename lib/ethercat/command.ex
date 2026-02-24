defmodule EtherCAT.Command do
  @moduledoc """
  Builder functions for EtherCAT command datagrams.

  Each function returns an `%EtherCAT.Datagram{}` with the correct CMD code
  and address field. The address layout depends on the addressing mode:

  - **Auto increment** (APRD, APWR, APRW, ARMW): position + offset
  - **Configured station** (FPRD, FPWR, FPRW, FRMW): address + offset
  - **Broadcast** (BRD, BWR, BRW): position=0 + offset
  - **Logical** (LRD, LWR, LRW): 32-bit logical address

  Position is a signed 16-bit value (the master sets it to the negative
  of the target slave's position; each slave increments it, and the slave
  that sees 0 is addressed). See spec §2.3.1.

  ## Examples

      Command.aprd(3, 0x0130, 2)
      Command.fpwr(0x03E9, 0x0120, <<0x08>>)
      Command.brd(0x0130, 4)
      Command.lrw(0x00010000, <<0, 0, 0, 0>>)
  """

  alias EtherCAT.Datagram

  # CMD codes from spec Table 6
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

  # ---------------------------------------------------------------------------
  # Auto increment commands (position + offset addressing)
  # ---------------------------------------------------------------------------

  @doc "Auto increment read. Reads `length` zero-filled bytes from slave at `position` (0-based)."
  @spec aprd(non_neg_integer(), non_neg_integer(), pos_integer()) :: Datagram.t()
  def aprd(position, offset, length) do
    %Datagram{
      cmd: @aprd,
      address: position_address(-position, offset),
      data: <<0::size(length)-unit(8)>>
    }
  end

  @doc "Auto increment write. `position` is 0-based."
  @spec apwr(non_neg_integer(), non_neg_integer(), binary()) :: Datagram.t()
  def apwr(position, offset, data) do
    %Datagram{cmd: @apwr, address: position_address(-position, offset), data: data}
  end

  @doc "Auto increment read/write. `position` is 0-based."
  @spec aprw(non_neg_integer(), non_neg_integer(), binary()) :: Datagram.t()
  def aprw(position, offset, data) do
    %Datagram{cmd: @aprw, address: position_address(-position, offset), data: data}
  end

  @doc """
  Auto increment read multiple write (ARMW). `position` is 0-based.

  The addressed slave (position=0 after increment) reads; all others write.
  WKC increments by 1 in either case (spec Table 7).
  """
  @spec armw(non_neg_integer(), non_neg_integer(), binary()) :: Datagram.t()
  def armw(position, offset, data) do
    %Datagram{cmd: @armw, address: position_address(-position, offset), data: data}
  end

  # ---------------------------------------------------------------------------
  # Configured station address commands (address + offset)
  # ---------------------------------------------------------------------------

  @doc "Configured address read."
  @spec fprd(non_neg_integer(), non_neg_integer(), pos_integer()) :: Datagram.t()
  def fprd(address, offset, length) do
    %Datagram{
      cmd: @fprd,
      address: station_address(address, offset),
      data: <<0::size(length)-unit(8)>>
    }
  end

  @doc "Configured address write."
  @spec fpwr(non_neg_integer(), non_neg_integer(), binary()) :: Datagram.t()
  def fpwr(address, offset, data) do
    %Datagram{cmd: @fpwr, address: station_address(address, offset), data: data}
  end

  @doc "Configured address read/write."
  @spec fprw(non_neg_integer(), non_neg_integer(), binary()) :: Datagram.t()
  def fprw(address, offset, data) do
    %Datagram{cmd: @fprw, address: station_address(address, offset), data: data}
  end

  @doc """
  Configured address read multiple write (FRMW).

  The addressed slave reads; all others write. WKC increments by 1 (spec Table 7).
  """
  @spec frmw(non_neg_integer(), non_neg_integer(), binary()) :: Datagram.t()
  def frmw(address, offset, data) do
    %Datagram{cmd: @frmw, address: station_address(address, offset), data: data}
  end

  # ---------------------------------------------------------------------------
  # Broadcast commands (position=0, offset)
  # All slaves are addressed. Position field is incremented by each slave
  # but not used for addressing (spec §2.3.1).
  # ---------------------------------------------------------------------------

  @doc "Broadcast read."
  @spec brd(non_neg_integer(), pos_integer()) :: Datagram.t()
  def brd(offset, length) do
    %Datagram{cmd: @brd, address: position_address(0, offset), data: <<0::size(length)-unit(8)>>}
  end

  @doc "Broadcast write."
  @spec bwr(non_neg_integer(), binary()) :: Datagram.t()
  def bwr(offset, data) do
    %Datagram{cmd: @bwr, address: position_address(0, offset), data: data}
  end

  @doc "Broadcast read/write. Typically not used (spec Table 6)."
  @spec brw(non_neg_integer(), binary()) :: Datagram.t()
  def brw(offset, data) do
    %Datagram{cmd: @brw, address: position_address(0, offset), data: data}
  end

  # ---------------------------------------------------------------------------
  # Logical memory commands (32-bit FMMU-mapped address)
  # ---------------------------------------------------------------------------

  @doc "Logical memory read."
  @spec lrd(non_neg_integer(), pos_integer()) :: Datagram.t()
  def lrd(logical_address, length) do
    %Datagram{
      cmd: @lrd,
      address: <<logical_address::little-unsigned-32>>,
      data: <<0::size(length)-unit(8)>>
    }
  end

  @doc "Logical memory write."
  @spec lwr(non_neg_integer(), binary()) :: Datagram.t()
  def lwr(logical_address, data) do
    %Datagram{cmd: @lwr, address: <<logical_address::little-unsigned-32>>, data: data}
  end

  @doc "Logical memory read/write."
  @spec lrw(non_neg_integer(), binary()) :: Datagram.t()
  def lrw(logical_address, data) do
    %Datagram{cmd: @lrw, address: <<logical_address::little-unsigned-32>>, data: data}
  end

  # ---------------------------------------------------------------------------
  # NOP
  # ---------------------------------------------------------------------------

  @doc "No operation — slave ignores this command entirely."
  @spec nop() :: Datagram.t()
  def nop, do: %Datagram{cmd: @nop}

  # ---------------------------------------------------------------------------
  # Address encoding
  # ---------------------------------------------------------------------------

  defp position_address(position, offset) do
    <<position::little-signed-16, offset::little-unsigned-16>>
  end

  defp station_address(address, offset) do
    <<address::little-unsigned-16, offset::little-unsigned-16>>
  end
end
