defmodule EtherCAT.Driver.CatalogueExample do
  @moduledoc false

  # Test-only, hypothetical device. See catalogue_example.md for the comparison.
  @behaviour EtherCAT.Driver

  alias EtherCAT.Driver.Signal
  alias EtherCAT.Endpoint

  # Each row owns the name, direction, scalar type, and PDO slice together.
  # The tuple deliberately reuses existing public structs; no new DSL is needed.
  @signals [
    {%Endpoint{signal: :controlword, direction: :output, type: :u16},
     Signal.slice(0x1600, 0, 16)},
    {%Endpoint{signal: :target_position, direction: :output, type: :i32},
     Signal.slice(0x1600, 16, 32)},
    {%Endpoint{signal: :statusword, direction: :input, type: :u16}, Signal.slice(0x1A00, 0, 16)},
    {%Endpoint{signal: :actual_position, direction: :input, type: :i32},
     Signal.slice(0x1A00, 16, 32)}
  ]

  @diagnostics [
    {%Endpoint{signal: :temperature, direction: :input, type: :i16}, Signal.slice(0x1A01, 0, 16)}
  ]

  @impl true
  def signal_model(config, _pdos) do
    Enum.map(catalogue(config), fn {endpoint, mapping} -> {endpoint.signal, mapping} end)
  end

  @impl true
  def describe(config) do
    %{
      device_type: :positioning_device,
      endpoints: Enum.map(catalogue(config), fn {endpoint, _mapping} -> endpoint end)
    }
  end

  @impl true
  def encode_signal(signal, config, value) do
    with {:ok, type} <- signal_type(signal, config, :output) do
      encode(type, value)
    end
  end

  @impl true
  def decode_signal(signal, config, raw) do
    with {:ok, type} <- signal_type(signal, config, :input) do
      decode(type, raw)
    end
  end

  # Enabling diagnostics describes an expected PDO, not a request to provision it.
  # Do not filter missing PDOs out: the existing planner must report the mismatch.
  defp catalogue(%{diagnostics?: true}), do: @signals ++ @diagnostics
  defp catalogue(_config), do: @signals

  defp signal_type(signal, config, direction) do
    case Enum.find(catalogue(config), fn {endpoint, _mapping} -> endpoint.signal == signal end) do
      {%Endpoint{direction: ^direction, type: type}, _mapping} -> {:ok, type}
      nil -> {:error, :unknown_signal}
      _other -> {:error, :wrong_direction}
    end
  end

  # Explicit little-endian scalar codecs, not inference from arbitrary type atoms.
  defp encode(:u16, value) when is_integer(value) and value >= 0 and value <= 65_535,
    do: {:ok, <<value::unsigned-little-16>>}

  defp encode(:i32, value)
       when is_integer(value) and value >= -2_147_483_648 and value <= 2_147_483_647,
       do: {:ok, <<value::signed-little-32>>}

  defp encode(_type, _value), do: {:error, :invalid_value}

  defp decode(:u16, <<value::unsigned-little-16>>), do: {:ok, value}
  defp decode(:i32, <<value::signed-little-32>>), do: {:ok, value}
  defp decode(:i16, <<value::signed-little-16>>), do: {:ok, value}
  defp decode(_type, _raw), do: {:error, :invalid_data}
end
