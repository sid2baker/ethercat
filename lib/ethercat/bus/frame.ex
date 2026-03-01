defmodule EtherCAT.Bus.Frame do
  @moduledoc false
  # EtherCAT frame encoder/decoder (spec §2.1).
  #
  # Encodes/decodes the EtherCAT payload: 2-byte EtherCAT header + datagrams.
  # The physical transport wrapper (Ethernet frame, UDP/IP) is handled by
  # the transport modules (Bus.Transport.RawSocket, Bus.Transport.UdpSocket).
  #
  # EtherCAT header layout (LSB first per spec):
  #   Bits [10:0]  Length — byte count of datagrams payload
  #   Bit  [11]    Reserved — always 0
  #   Bits [15:12] Type — must be 0x1 (ESCs ignore other types)
  #
  # Note: the EtherCAT header Length field is ignored by ESCs (they rely on
  # per-datagram length fields), but we populate it correctly for
  # interoperability.

  alias EtherCAT.Bus.Datagram

  # EtherCAT header length field is 11 bits → protocol max 2047 bytes.
  # The practical network limit (~1400 bytes for datagrams) is enforced
  # upstream in SinglePort/Redundant via @max_datagram_bytes.
  @max_payload 2047

  @spec encode([Datagram.t()]) :: {:ok, binary()} | {:error, :frame_too_large}
  def encode(datagrams) do
    payload = Datagram.encode(datagrams)
    len = byte_size(payload)

    if len > @max_payload do
      {:error, :frame_too_large}
    else
      # EtherCAT header: Type[15:12]=1 | R[11]=0 | Length[10:0]
      # Pack MSB-first, reinterpret as little-endian 16.
      <<ecat_header::big-unsigned-16>> = <<1::4, 0::1, len::11>>
      {:ok, <<ecat_header::little-unsigned-16, payload::binary>>}
    end
  end

  @spec decode(binary()) :: {:ok, [Datagram.t()]} | {:error, atom()}
  def decode(<<ecat_header::little-unsigned-16, rest::binary>>) do
    <<type::4, _r::1, _len::11>> = <<ecat_header::big-unsigned-16>>

    case type do
      1 ->
        case Datagram.decode(rest) do
          {:ok, datagrams} -> {:ok, datagrams}
          error -> error
        end

      _ ->
        {:error, :unsupported_type}
    end
  end

  def decode(_), do: {:error, :truncated_header}
end
