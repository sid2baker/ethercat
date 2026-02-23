defmodule Ethercat.Protocol.Datagram do
  @moduledoc """
  EtherCAT datagram representation. We purposely keep the structure simple so
  the higher layers can reason about the command, logical address and payload
  without having to manipulate binaries directly.
  """

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

  defstruct [:command, :index, :address, :length, :data, :working_counter]

  @type t :: %__MODULE__{
          command: command(),
          index: non_neg_integer(),
          address: non_neg_integer(),
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

    <<
      command::4,
      dg.index::8,
      dg.address::16-little,
      dg.length::11,
      0::5,
      data::binary,
      wc::16-little
    >>
  end

  @doc """
  Convenience constructor for LRW datagrams.
  """
  def lrw(address, length, data) do
    %__MODULE__{command: :lrw, address: address, length: length, data: data, index: 0}
  end
end
