defmodule EtherCAT.Link.Command do
  @moduledoc false
  # Internal datagram builder — not part of the public API.
  # Callers should use EtherCAT.Link.fprd/fpwr/lrw/brd/... directly.

  alias EtherCAT.Link.Datagram

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

  # Auto increment
  def aprd(position, offset, length),
    do: %Datagram{cmd: @aprd, address: position_address(-position, offset), data: <<0::size(length)-unit(8)>>}

  def apwr(position, offset, data),
    do: %Datagram{cmd: @apwr, address: position_address(-position, offset), data: data}

  def aprw(position, offset, data),
    do: %Datagram{cmd: @aprw, address: position_address(-position, offset), data: data}

  def armw(position, offset, data),
    do: %Datagram{cmd: @armw, address: position_address(-position, offset), data: data}

  # Configured station
  def fprd(address, offset, length),
    do: %Datagram{cmd: @fprd, address: station_address(address, offset), data: <<0::size(length)-unit(8)>>}

  def fpwr(address, offset, data),
    do: %Datagram{cmd: @fpwr, address: station_address(address, offset), data: data}

  def fprw(address, offset, data),
    do: %Datagram{cmd: @fprw, address: station_address(address, offset), data: data}

  def frmw(address, offset, data),
    do: %Datagram{cmd: @frmw, address: station_address(address, offset), data: data}

  # Broadcast
  def brd(offset, length),
    do: %Datagram{cmd: @brd, address: position_address(0, offset), data: <<0::size(length)-unit(8)>>}

  def bwr(offset, data),
    do: %Datagram{cmd: @bwr, address: position_address(0, offset), data: data}

  def brw(offset, data),
    do: %Datagram{cmd: @brw, address: position_address(0, offset), data: data}

  # Logical
  def lrd(logical_address, length),
    do: %Datagram{cmd: @lrd, address: <<logical_address::little-unsigned-32>>, data: <<0::size(length)-unit(8)>>}

  def lwr(logical_address, data),
    do: %Datagram{cmd: @lwr, address: <<logical_address::little-unsigned-32>>, data: data}

  def lrw(logical_address, data),
    do: %Datagram{cmd: @lrw, address: <<logical_address::little-unsigned-32>>, data: data}

  # NOP
  def nop, do: %Datagram{cmd: @nop}

  defp position_address(position, offset),
    do: <<position::little-signed-16, offset::little-unsigned-16>>

  defp station_address(address, offset),
    do: <<address::little-unsigned-16, offset::little-unsigned-16>>
end
