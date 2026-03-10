defmodule EtherCAT.Simulator.Slave.Value do
  @moduledoc false

  @type scalar_type ::
          :bool
          | :u8
          | :u16
          | :u32
          | :u64
          | :i8
          | :i16
          | :i32
          | :i64
          | :f32
          | :f64
          | {:uint, pos_integer()}
          | {:int, pos_integer()}
          | {:binary, pos_integer()}

  @type metadata :: %{
          optional(:type) => scalar_type(),
          optional(:bit_size) => pos_integer(),
          optional(:scale) => number(),
          optional(:offset) => number()
        }

  @spec bit_width(metadata()) :: pos_integer()
  def bit_width(metadata) do
    case Map.get(metadata, :bit_size) do
      nil -> default_bit_size(Map.fetch!(metadata, :type))
      bits -> bits
    end
  end

  @spec byte_width(metadata()) :: pos_integer()
  def byte_width(metadata) do
    bits = bit_width(metadata)

    if rem(bits, 8) == 0 do
      div(bits, 8)
    else
      raise ArgumentError, "value is not byte aligned"
    end
  end

  @spec encode_integer(metadata(), term()) :: {:ok, non_neg_integer()} | {:error, :invalid_value}
  def encode_integer(%{type: {:binary, _size}}, _value), do: {:error, :invalid_value}

  def encode_integer(metadata, value) do
    bits = bit_width(metadata)

    if rem(bits, 8) == 0 and byte_aligned_type?(Map.fetch!(metadata, :type)) do
      with {:ok, binary} <- encode_binary(metadata, value) do
        {:ok, :binary.decode_unsigned(binary, :little)}
      end
    else
      encode_non_byte_aligned(metadata, value)
    end
  end

  @spec decode_integer(metadata(), non_neg_integer()) :: term()
  def decode_integer(%{type: {:binary, size}}, value)
      when is_integer(value) and value >= 0 do
    value
    |> :binary.encode_unsigned(:little)
    |> pad_trailing_zeros(size)
  end

  def decode_integer(metadata, value) when is_integer(value) and value >= 0 do
    bits = bit_width(metadata)

    if rem(bits, 8) == 0 and byte_aligned_type?(Map.fetch!(metadata, :type)) do
      binary =
        value
        |> :binary.encode_unsigned(:little)
        |> pad_trailing_zeros(byte_width(metadata))

      decode_binary(metadata, binary)
    else
      decode_non_byte_aligned(metadata, value)
    end
  end

  @spec encode_binary(metadata(), term()) :: {:ok, binary()} | {:error, :invalid_value}
  def encode_binary(%{type: :bool}, true), do: {:ok, <<1>>}
  def encode_binary(%{type: :bool}, false), do: {:ok, <<0>>}

  def encode_binary(metadata, value) do
    type = Map.fetch!(metadata, :type)
    scale = Map.get(metadata, :scale, 1)
    offset = Map.get(metadata, :offset, 0)

    case normalize_value(type, value, scale, offset) do
      {:ok, normalized} ->
        encode_typed_binary(type, normalized)

      {:error, _} ->
        {:error, :invalid_value}
    end
  end

  @spec decode_binary(metadata(), binary()) :: term()
  def decode_binary(%{type: :bool}, <<0>>), do: false
  def decode_binary(%{type: :bool}, <<_nonzero>>), do: true

  def decode_binary(metadata, binary) do
    type = Map.fetch!(metadata, :type)
    scale = Map.get(metadata, :scale, 1)
    offset = Map.get(metadata, :offset, 0)

    type
    |> decode_typed_binary(binary)
    |> apply_scale(scale, offset)
  end

  @spec default_bit_size(scalar_type()) :: pos_integer()
  def default_bit_size(:bool), do: 1
  def default_bit_size(:u8), do: 8
  def default_bit_size(:u16), do: 16
  def default_bit_size(:u32), do: 32
  def default_bit_size(:u64), do: 64
  def default_bit_size(:i8), do: 8
  def default_bit_size(:i16), do: 16
  def default_bit_size(:i32), do: 32
  def default_bit_size(:i64), do: 64
  def default_bit_size(:f32), do: 32
  def default_bit_size(:f64), do: 64
  def default_bit_size({:uint, bits}), do: bits
  def default_bit_size({:int, bits}), do: bits
  def default_bit_size({:binary, size}), do: size * 8

  defp byte_aligned_type?(:bool), do: true
  defp byte_aligned_type?(:u8), do: true
  defp byte_aligned_type?(:u16), do: true
  defp byte_aligned_type?(:u32), do: true
  defp byte_aligned_type?(:u64), do: true
  defp byte_aligned_type?(:i8), do: true
  defp byte_aligned_type?(:i16), do: true
  defp byte_aligned_type?(:i32), do: true
  defp byte_aligned_type?(:i64), do: true
  defp byte_aligned_type?(:f32), do: true
  defp byte_aligned_type?(:f64), do: true
  defp byte_aligned_type?({:binary, _size}), do: true
  defp byte_aligned_type?({:uint, bits}), do: rem(bits, 8) == 0
  defp byte_aligned_type?({:int, bits}), do: rem(bits, 8) == 0

  defp encode_non_byte_aligned(%{type: :bool}, true), do: {:ok, 1}
  defp encode_non_byte_aligned(%{type: :bool}, false), do: {:ok, 0}

  defp encode_non_byte_aligned(metadata, value) when is_integer(value) or is_float(value) do
    scale = Map.get(metadata, :scale, 1)
    offset = Map.get(metadata, :offset, 0)

    with {:ok, raw} <- normalize_numeric(value, scale, offset),
         true <- raw_fits?(metadata, raw) do
      {:ok, encode_integer_bits(Map.fetch!(metadata, :type), bit_width(metadata), raw)}
    else
      _ -> {:error, :invalid_value}
    end
  end

  defp encode_non_byte_aligned(_metadata, _value), do: {:error, :invalid_value}

  defp decode_non_byte_aligned(%{type: :bool}, 0), do: false
  defp decode_non_byte_aligned(%{type: :bool}, _value), do: true

  defp decode_non_byte_aligned(metadata, value) do
    raw = decode_integer_bits(Map.fetch!(metadata, :type), bit_width(metadata), value)
    apply_scale(raw, Map.get(metadata, :scale, 1), Map.get(metadata, :offset, 0))
  end

  defp encode_typed_binary(:bool, value), do: {:ok, <<value::8>>}
  defp encode_typed_binary(:u8, value), do: {:ok, <<value::8>>}
  defp encode_typed_binary(:u16, value), do: {:ok, <<value::16-little>>}
  defp encode_typed_binary(:u32, value), do: {:ok, <<value::32-little>>}
  defp encode_typed_binary(:u64, value), do: {:ok, <<value::64-little>>}
  defp encode_typed_binary(:i8, value), do: {:ok, <<value::8-signed>>}
  defp encode_typed_binary(:i16, value), do: {:ok, <<value::16-signed-little>>}
  defp encode_typed_binary(:i32, value), do: {:ok, <<value::32-signed-little>>}
  defp encode_typed_binary(:i64, value), do: {:ok, <<value::64-signed-little>>}
  defp encode_typed_binary(:f32, value), do: {:ok, <<value::float-32-little>>}
  defp encode_typed_binary(:f64, value), do: {:ok, <<value::float-64-little>>}

  defp encode_typed_binary({:uint, bits}, value) when rem(bits, 8) == 0 do
    {:ok, <<value::unsigned-little-size(bits)>>}
  end

  defp encode_typed_binary({:int, bits}, value) when rem(bits, 8) == 0 do
    {:ok, <<value::signed-little-size(bits)>>}
  end

  defp encode_typed_binary({:binary, size}, value)
       when is_binary(value) and byte_size(value) <= size do
    {:ok, value <> :binary.copy(<<0>>, size - byte_size(value))}
  end

  defp encode_typed_binary(_type, _value), do: {:error, :invalid_value}

  defp decode_typed_binary(:bool, <<0>>), do: 0
  defp decode_typed_binary(:bool, <<_nonzero>>), do: 1
  defp decode_typed_binary(:u8, <<value::8>>), do: value
  defp decode_typed_binary(:u16, <<value::16-little>>), do: value
  defp decode_typed_binary(:u32, <<value::32-little>>), do: value
  defp decode_typed_binary(:u64, <<value::64-little>>), do: value
  defp decode_typed_binary(:i8, <<value::8-signed>>), do: value
  defp decode_typed_binary(:i16, <<value::16-signed-little>>), do: value
  defp decode_typed_binary(:i32, <<value::32-signed-little>>), do: value
  defp decode_typed_binary(:i64, <<value::64-signed-little>>), do: value
  defp decode_typed_binary(:f32, <<value::float-32-little>>), do: value
  defp decode_typed_binary(:f64, <<value::float-64-little>>), do: value

  defp decode_typed_binary({:uint, bits}, binary) do
    <<value::unsigned-little-size(bits)>> = binary
    value
  end

  defp decode_typed_binary({:int, bits}, binary) do
    <<value::signed-little-size(bits)>> = binary
    value
  end

  defp decode_typed_binary({:binary, _size}, value), do: value

  defp normalize_value(:bool, value, scale, offset) when value in [true, false] do
    normalize_numeric(if(value, do: 1, else: 0), scale, offset)
  end

  defp normalize_value(_type, value, scale, offset) when value in [true, false] do
    normalize_numeric(if(value, do: 1, else: 0), scale, offset)
  end

  defp normalize_value({:binary, size}, value, _scale, _offset)
       when is_binary(value) and byte_size(value) <= size do
    {:ok, value}
  end

  defp normalize_value(type, value, _scale, _offset)
       when type in [:f32, :f64] and is_number(value) do
    {:ok, value}
  end

  defp normalize_value(_type, value, scale, offset) when is_integer(value) or is_float(value) do
    normalize_numeric(value, scale, offset)
  end

  defp normalize_value(_type, _value, _scale, _offset), do: {:error, :invalid_value}

  defp normalize_numeric(_value, scale, _offset) when scale in [0, 0.0], do: {:error, :invalid}

  defp normalize_numeric(value, scale, offset) do
    raw = (value - offset) / scale
    rounded = round(raw)

    if nearly_equal?(raw, rounded) do
      {:ok, rounded}
    else
      {:error, :invalid}
    end
  end

  defp raw_fits?(metadata, raw) do
    case Map.fetch!(metadata, :type) do
      :bool ->
        raw in [0, 1]

      :u8 ->
        raw >= 0 and raw <= 0xFF

      :u16 ->
        raw >= 0 and raw <= 0xFFFF

      :u32 ->
        raw >= 0 and raw <= 0xFFFF_FFFF

      :u64 ->
        raw >= 0

      {:uint, bits} ->
        raw >= 0 and raw < Integer.pow(2, bits)

      type ->
        raw >= signed_min(type, bit_width(metadata)) and
          raw <= signed_max(type, bit_width(metadata))
    end
  end

  defp encode_integer_bits(:bool, _bits, raw), do: raw
  defp encode_integer_bits(:u8, _bits, raw), do: raw
  defp encode_integer_bits(:u16, _bits, raw), do: raw
  defp encode_integer_bits(:u32, _bits, raw), do: raw
  defp encode_integer_bits(:u64, _bits, raw), do: raw
  defp encode_integer_bits({:uint, _bits}, _width, raw), do: raw

  defp encode_integer_bits(_type, bits, raw) do
    if raw < 0 do
      raw + Integer.pow(2, bits)
    else
      raw
    end
  end

  defp decode_integer_bits(:bool, _bits, raw), do: raw
  defp decode_integer_bits(:u8, _bits, raw), do: raw
  defp decode_integer_bits(:u16, _bits, raw), do: raw
  defp decode_integer_bits(:u32, _bits, raw), do: raw
  defp decode_integer_bits(:u64, _bits, raw), do: raw
  defp decode_integer_bits({:uint, _bits}, _width, raw), do: raw

  defp decode_integer_bits(_type, bits, raw) do
    sign_threshold = Integer.pow(2, bits - 1)

    if raw >= sign_threshold do
      raw - Integer.pow(2, bits)
    else
      raw
    end
  end

  defp signed_min(:i8, bits), do: -Integer.pow(2, bits - 1)
  defp signed_min(:i16, bits), do: -Integer.pow(2, bits - 1)
  defp signed_min(:i32, bits), do: -Integer.pow(2, bits - 1)
  defp signed_min(:i64, bits), do: -Integer.pow(2, bits - 1)
  defp signed_min({:int, _bits}, bits), do: -Integer.pow(2, bits - 1)

  defp signed_max(:i8, bits), do: Integer.pow(2, bits - 1) - 1
  defp signed_max(:i16, bits), do: Integer.pow(2, bits - 1) - 1
  defp signed_max(:i32, bits), do: Integer.pow(2, bits - 1) - 1
  defp signed_max(:i64, bits), do: Integer.pow(2, bits - 1) - 1
  defp signed_max({:int, _bits}, bits), do: Integer.pow(2, bits - 1) - 1

  defp apply_scale(value, 1, 0), do: value
  defp apply_scale(value, scale, offset), do: value * scale + offset

  defp nearly_equal?(left, right) when is_integer(left) and is_integer(right), do: left == right
  defp nearly_equal?(left, right), do: abs(left - right) < 1.0e-9

  defp pad_trailing_zeros(binary, size) when byte_size(binary) >= size do
    binary_part(binary, 0, size)
  end

  defp pad_trailing_zeros(binary, size) do
    binary <> :binary.copy(<<0>>, size - byte_size(binary))
  end
end
