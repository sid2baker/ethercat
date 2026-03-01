defmodule EtherCAT.Bus.Datagram do
  @moduledoc """
  An EtherCAT datagram struct and wire-format codec (spec §2.2).

  ## Wire layout (all little-endian, LSB first)

      Byte  0:     CMD (8 bit)
      Byte  1:     IDX (8 bit)
      Bytes 2–5:   Address (32 bit, layout depends on CMD)
      Bytes 6–7:   Len[10:0] | R[13:11]=0 | C[14] | M[15]
      Bytes 8–9:   IRQ (16 bit)
      Bytes 10…n:  Data (Len bytes)
      Last 2:      WKC (16 bit)

  The circulating bit (C) is a slave-side mechanism for detecting frames
  that loop in a ring after a cable break (spec §3.5). The master always
  sends C=0; a returned C=1 means the frame circulated (error condition).
  """

  @type t :: %__MODULE__{
          cmd: 0..14,
          idx: byte(),
          address: <<_::32>>,
          data: binary(),
          wkc: non_neg_integer(),
          irq: non_neg_integer(),
          circular: boolean()
        }

  defstruct cmd: 0,
            idx: 0,
            address: <<0, 0, 0, 0>>,
            data: <<>>,
            wkc: 0,
            irq: 0,
            circular: false

  @header_size 10
  @wkc_size 2

  @doc """
  Encode a list of datagrams into a contiguous binary.

  Sets the M (more) bit on all but the last datagram.
  The C (circulating) bit is always sent as 0.
  """
  @spec encode([t()]) :: binary()
  def encode(datagrams) when is_list(datagrams) do
    last = length(datagrams) - 1

    datagrams
    |> Enum.with_index()
    |> Enum.map(fn {dg, i} -> encode_one(dg, i < last) end)
    |> IO.iodata_to_binary()
  end

  @doc """
  Decode a binary into a list of datagrams.
  Trailing padding bytes (after the last datagram where M=0) are ignored.
  """
  @spec decode(binary()) :: {:ok, [t()]} | {:error, atom()}
  def decode(bin) when is_binary(bin), do: decode_loop(bin, [])

  @doc "Encoded size in bytes: 10-byte header + data + 2-byte WKC."
  @spec wire_size(t()) :: non_neg_integer()
  def wire_size(%__MODULE__{data: data}), do: @header_size + byte_size(data) + @wkc_size

  # -- encode -----------------------------------------------------------------

  defp encode_one(%__MODULE__{} = dg, more?) do
    len = byte_size(dg.data)
    m = if more?, do: 1, else: 0

    # Datagram length field: M[15] | C[14] | R[13:11]=0 | Len[10:0]
    # Pack bit fields MSB-first, then reinterpret as little-endian 16.
    <<len_field::big-unsigned-16>> = <<m::1, 0::1, 0::3, len::11>>

    <<
      dg.cmd::8,
      dg.idx::8,
      dg.address::binary-size(4),
      len_field::little-unsigned-16,
      dg.irq::little-unsigned-16,
      dg.data::binary,
      dg.wkc::little-unsigned-16
    >>
  end

  # -- decode -----------------------------------------------------------------

  defp decode_loop(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_loop(
         <<
           cmd::8,
           idx::8,
           address::binary-size(4),
           len_field::little-unsigned-16,
           irq::little-unsigned-16,
           rest::binary
         >>,
         acc
       ) do
    <<m::1, c::1, _r::3, len::11>> = <<len_field::big-unsigned-16>>

    case rest do
      <<data::binary-size(len), wkc::little-unsigned-16, tail::binary>> ->
        dg = %__MODULE__{
          cmd: cmd,
          idx: idx,
          address: address,
          data: data,
          wkc: wkc,
          irq: irq,
          circular: c == 1
        }

        case m do
          1 -> decode_loop(tail, [dg | acc])
          0 -> {:ok, Enum.reverse([dg | acc])}
        end

      _ ->
        {:error, :truncated_data}
    end
  end

  defp decode_loop(bin, _acc) when byte_size(bin) > 0 and byte_size(bin) < @header_size do
    {:error, :truncated_header}
  end

  defp decode_loop(_bin, _acc), do: {:error, :malformed}
end
