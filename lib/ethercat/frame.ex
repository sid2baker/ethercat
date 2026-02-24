defmodule EtherCAT.Frame do
  @moduledoc """
  Encode and decode Ethernet frames carrying EtherCAT data.

  ## Wire layout

      Destination MAC  (6 bytes)  — broadcast FF:FF:FF:FF:FF:FF
      Source MAC       (6 bytes)  — default 00:00:00:00:00:00
      EtherType        (2 bytes)  — 0x88A4
      EtherCAT Header  (2 bytes)  — Length[10:0] | R[11]=0 | Type[15:12]=1
      Datagrams        (variable)
      Padding          (to 60 bytes minimum, FCS added by NIC)

  EtherCAT header type must be 1 (spec §2.1, Table 2). The length field
  is ignored by ESCs (they rely on individual datagram length fields), but
  we set it correctly per spec.

  VLAN-tagged frames (IEEE 802.1Q, EtherType 0x8100) are supported on
  decode — the VLAN tag is skipped, matching ESC behavior (spec §3).

  FCS is computed by NIC hardware and not included here.
  """

  alias EtherCAT.Datagram

  @broadcast_mac <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
  @zero_mac <<0, 0, 0, 0, 0, 0>>
  @min_frame_size 60
  # EtherCAT header length field is 11 bits → max 2047 bytes of datagram payload.
  @max_payload 2047

  @doc """
  Encode datagrams into a complete Ethernet frame.

  Returns `{:ok, frame}` or `{:error, :frame_too_large}` when the combined
  datagram payload exceeds the 11-bit length field (2047 bytes).

  `src_mac` is a 6-byte binary source MAC address (default all-zeros).
  Destination is always broadcast.
  """
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

  @doc """
  Decode a received Ethernet frame.

  Returns `{:ok, datagrams, src_mac}` or `{:error, reason}`.
  """
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
