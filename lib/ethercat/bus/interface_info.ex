defmodule EtherCAT.Bus.InterfaceInfo do
  @moduledoc false

  @sysfs_net "/sys/class/net"

  @spec mac_address(String.t()) :: {:ok, <<_::48>>} | {:error, term()}
  def mac_address(interface) when is_binary(interface) and byte_size(interface) > 0 do
    with {:ok, mac_str} <- mac_address_string(interface),
         {:ok, mac} <- decode_mac(mac_str) do
      {:ok, mac}
    end
  end

  @spec mac_address_string(String.t()) :: {:ok, String.t()} | {:error, term()}
  def mac_address_string(interface) when is_binary(interface) and byte_size(interface) > 0 do
    interface
    |> sysfs_path("address")
    |> File.read()
    |> case do
      {:ok, mac_str} ->
        {:ok, mac_str |> String.trim() |> String.downcase()}

      {:error, reason} ->
        {:error, {:no_mac_address, interface, reason}}
    end
  end

  @spec carrier_up?(String.t()) :: boolean()
  def carrier_up?(interface) when is_binary(interface) and byte_size(interface) > 0 do
    case read_carrier(interface) do
      {:ok, true} -> true
      {:ok, false} -> false
      {:error, _} -> operstate_up?(interface)
    end
  end

  defp read_carrier(interface) do
    interface
    |> sysfs_path("carrier")
    |> File.read()
    |> case do
      {:ok, "1\n"} -> {:ok, true}
      {:ok, "1"} -> {:ok, true}
      {:ok, "0\n"} -> {:ok, false}
      {:ok, "0"} -> {:ok, false}
      {:ok, _other} -> {:error, :invalid_carrier}
      {:error, reason} -> {:error, reason}
    end
  end

  defp operstate_up?(interface) do
    interface
    |> sysfs_path("operstate")
    |> File.read()
    |> case do
      {:ok, operstate} ->
        operstate
        |> String.trim()
        |> Kernel.in(["up"])

      {:error, _} ->
        false
    end
  end

  defp decode_mac(mac_str) do
    parts = String.split(mac_str, ":")

    if length(parts) == 6 do
      try do
        mac =
          parts
          |> Enum.map(&String.to_integer(&1, 16))
          |> :binary.list_to_bin()

        {:ok, mac}
      rescue
        ArgumentError -> {:error, :invalid_mac_address}
      end
    else
      {:error, :invalid_mac_address}
    end
  end

  defp sysfs_path(interface, leaf), do: Path.join([@sysfs_net, interface, leaf])
end
