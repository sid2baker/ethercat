defmodule Ethercat.Protocol.Frame do
  @moduledoc """
  EtherCAT frame encoder/decoder.
  """

  import Bitwise
  alias Ethercat.Protocol.Datagram

  @ether_type 0x88A4

  @doc """
  Builds a binary frame from the provided datagrams.
  """
  @spec build([Datagram.t()], keyword()) :: binary()
  def build(datagrams, opts) when is_list(datagrams) do
    src_mac = Keyword.fetch!(opts, :src_mac)
    dest_mac = Keyword.get(opts, :dest_mac, :binary.copy(<<0xFF>>, 6))

    payload = Enum.map(datagrams, &Datagram.encode/1) |> IO.iodata_to_binary()
    frame_length = byte_size(payload)

    # EtherCAT header is 2 bytes little-endian: bits 0..10 length, bit 11 reserved,
    # bits 12..15 type (1 = EtherCAT datagrams).
    header = bor(bsl(1, 12), frame_length)

    <<
      dest_mac::binary-size(6),
      src_mac::binary-size(6),
      @ether_type::16-big,
      header::16-little,
      payload::binary
    >>
  end

  @doc """
  Parses a binary frame into a list of datagrams.
  """
  @spec parse(binary()) :: {:ok, [Datagram.t()]} | {:error, term()}
  def parse(<<_dest::48, _src::48, @ether_type::16, header::16-little, rest::binary>>) do
    length = band(header, 0x07FF)

    if byte_size(rest) >= length do
      <<payload::binary-size(length), _tail::binary>> = rest
      decode_datagrams(payload, [])
    else
      {:error, :truncated}
    end
  end

  def parse(_), do: {:error, :invalid_frame}

  defp decode_datagrams(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_datagrams(payload, acc) do
    with <<cmd::8, idx::8, adp::16-little-signed, ado::16-little, len_field::16-little,
           _irq::16-little, rest::binary>> <- payload,
         length <- band(len_field, 0x07FF),
         true <- byte_size(rest) >= length + 2,
         <<data::binary-size(length), wc::16-little, tail::binary>> <- rest,
         {:ok, command} <- decode_command(cmd) do
      datagram = %Datagram{
        command: command,
        index: idx,
        adp: adp,
        ado: ado,
        length: length,
        data: data,
        working_counter: wc
      }

      decode_datagrams(tail, [datagram | acc])
    else
      _ -> {:error, :malformed_datagram}
    end
  end

  defp decode_command(code) do
    case Enum.find(Datagram.command_map(), fn {_k, v} -> v == code end) do
      {cmd, _} -> {:ok, cmd}
      nil -> {:error, :unknown_command}
    end
  end
end
