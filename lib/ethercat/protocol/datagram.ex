defmodule Ethercat.Protocol.Datagram do
  @moduledoc """
  EtherCAT datagram representation. We purposely keep the structure simple so
  the higher layers can reason about the command, logical address and payload
  without having to manipulate binaries directly.
  """

  import Bitwise

  @typedoc """
  Working counter as defined in ETG.1000.
  """
  @type working_counter :: non_neg_integer()

  @typedoc """
  Command identifier (0..13).
  """
  @type command ::
          :nop
          | :aprd
          | :apwr
          | :aprw
          | :fprd
          | :fpwr
          | :fprw
          | :brd
          | :bwr
          | :brw
          | :lrd
          | :lwr
          | :lrw
          | :armw

  @command_map %{
    nop: 0,
    aprd: 1,
    apwr: 2,
    aprw: 3,
    fprd: 4,
    fpwr: 5,
    fprw: 6,
    brd: 7,
    bwr: 8,
    brw: 9,
    lrd: 10,
    lwr: 11,
    lrw: 12,
    armw: 13
  }

  defstruct [:command, :index, :adp, :ado, :length, :data, :working_counter]

  @type t :: %__MODULE__{
          command: command(),
          index: non_neg_integer(),
          adp: integer(),
          ado: non_neg_integer(),
          length: non_neg_integer(),
          data: binary(),
          working_counter: working_counter() | nil
        }

  @doc """
  Encodes the datagram into the on-wire binary representation.
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = dg) do
    command = Map.fetch!(@command_map, dg.command)
    wc = dg.working_counter || 0
    data = dg.data || <<>>
    length_field = band(dg.length, 0x07FF)

    adp = dg.adp || 0
    ado = dg.ado || 0

    <<
      command::8,
      dg.index::8,
      adp::16-little-signed,
      ado::16-little,
      length_field::16-little,
      0::16,
      data::binary,
      wc::16-little
    >>
  end

  @doc """
  Broadcast read.
  """
  def brd(offset, length) do
    data = :binary.copy(<<0>>, length)
    build(:brd, 0, offset, length, data)
  end

  @doc """
  Auto-increment physical write.
  """
  def apwr(adp, offset, data) do
    build(:apwr, adp, offset, byte_size(data), data)
  end

  @doc """
  Configured address physical read.
  """
  def fprd(station_address, offset, length) do
    data = :binary.copy(<<0>>, length)
    build(:fprd, station_address, offset, length, data)
  end

  @doc """
  Configured address physical write.
  """
  def fpwr(station_address, offset, data) do
    build(:fpwr, station_address, offset, byte_size(data), data)
  end

  @doc """
  Configured address physical read/write.

  Writes the provided data and returns the read-back data in the response.
  """
  def fprw(station_address, offset, data) do
    build(:fprw, station_address, offset, byte_size(data), data)
  end

  @doc """
  Logical write.
  """
  def lwr(logical_address, length, data) do
    build(:lwr, 0, logical_address, length, data)
  end

  @doc """
  Logical read.
  """
  def lrd(logical_address, length) do
    data = :binary.copy(<<0>>, length)
    build(:lrd, 0, logical_address, length, data)
  end

  defp build(command, adp, ado, length, data) when byte_size(data) == length do
    %__MODULE__{command: command, adp: adp, ado: ado, length: length, data: data, index: 0}
  end

  defp build(_command, _adp, _ado, length, data) do
    raise ArgumentError, "payload length mismatch: expected #{length} got #{byte_size(data)}"
  end

  @doc false
  def command_map, do: @command_map
end
