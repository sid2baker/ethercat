defmodule EtherCAT.Link.Frame do
  @moduledoc false
  # Internal Ethernet frame encoder/decoder — not part of the public API.

  alias EtherCAT.Link.Datagram

  @broadcast_mac <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
  @zero_mac <<0, 0, 0, 0, 0, 0>>
  @min_frame_size 60
  # EtherCAT header length field is 11 bits → max 2047 bytes of datagram payload.
  @max_payload 2047

  @spec encode([Datagram.t()], <<_::48>>) :: {:ok, binary()} | {:error, :frame_too_large}
  def encode(datagrams, src_mac \\ @zero_mac) do
    payload = Datagram.encode(datagrams)
    len = byte_size(payload)

    if len > @max_payload do
      {:error, :frame_too_large}
    else
      # EtherCAT header: Type[15:12]=1 | R[11]=0 | Length[10:0]
      # Pack bit fields in MSB-first order, then reinterpret as little-endian 16.
      <<ecat_header::big-unsigned-16>> = <<1::4, 0::1, len::11>>

      frame = <<
        @broadcast_mac::binary,
        src_mac::binary-size(6),
        0x88A4::big-unsigned-16,
        ecat_header::little-unsigned-16,
        payload::binary
      >>

      pad_needed = max(0, @min_frame_size - byte_size(frame))
      {:ok, <<frame::binary, 0::size(pad_needed)-unit(8)>>}
    end
  end

  @spec decode(binary()) :: {:ok, [Datagram.t()], <<_::48>>} | {:error, atom()}

  # Standard EtherCAT frame
  def decode(<<
        _dst::binary-size(6),
        src::binary-size(6),
        0x88A4::big-unsigned-16,
        ecat_header::little-unsigned-16,
        rest::binary
      >>) do
    <<type::4, _r::1, _len::11>> = <<ecat_header::big-unsigned-16>>
    decode_payload(type, rest, src)
  end

  # VLAN-tagged frame (802.1Q tag 0x8100 before actual EtherType)
  def decode(<<
        _dst::binary-size(6),
        src::binary-size(6),
        0x8100::big-unsigned-16,
        _vlan::binary-size(2),
        0x88A4::big-unsigned-16,
        ecat_header::little-unsigned-16,
        rest::binary
      >>) do
    <<type::4, _r::1, _len::11>> = <<ecat_header::big-unsigned-16>>
    decode_payload(type, rest, src)
  end

  def decode(_), do: {:error, :not_ethercat}

  defp decode_payload(1, payload, src_mac) do
    case Datagram.decode(payload) do
      {:ok, datagrams} -> {:ok, datagrams, src_mac}
      error -> error
    end
  end

  defp decode_payload(_type, _payload, _src_mac), do: {:error, :unsupported_type}
end
