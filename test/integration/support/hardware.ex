defmodule EtherCAT.IntegrationSupport.Hardware do
  @moduledoc false

  @spec interface() :: {:ok, binary()} | {:error, binary()}
  def interface do
    case System.get_env("ETHERCAT_INTERFACE") do
      nil ->
        {:error, "set ETHERCAT_INTERFACE to run hardware integration tests"}

      "" ->
        {:error, "set ETHERCAT_INTERFACE to run hardware integration tests"}

      interface ->
        if File.exists?("/sys/class/net/#{interface}") do
          {:ok, interface}
        else
          {:error, "EtherCAT interface #{inspect(interface)} does not exist"}
        end
    end
  end
end
