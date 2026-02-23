defmodule Ethercat.Protocol.Frame do
  @moduledoc """
  Minimal EtherCAT frame encoder/decoder used by the upper layers. The encoder
  only supports a subset of the spec that covers the LRW/LRD/LWR flows we rely
  on for process data exchange.
  """

  alias Ethercat.Protocol.Datagram

  @ether_type <<0x88, 0xA4>>

  @doc """
  Builds a binary frame from the provided datagrams. The transport layer may
  elect not to send the bytes anywhere (the current placeholder simply
  exercises the encoder), but keeping the conversion logic in one place makes
  it straightforward to swap in the raw-socket backend later.
  """
  @spec build([Datagram.t()]) :: binary()
  def build(datagrams) when is_list(datagrams) do
    payload = Enum.map_join(datagrams, &Datagram.encode/1)
    frame_length = byte_size(payload)

    <<
      # Destination MAC / Source MAC – filled with zeros for placeholder use
      0::48,
      0::48,
      @ether_type::binary,
      frame_length::11,
      0::1,
      1::4,
      payload::binary
    >>
  end
end
