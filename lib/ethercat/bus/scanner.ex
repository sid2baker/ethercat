defmodule Ethercat.Bus.Scanner do
  @moduledoc """
  Stubbed bus scanning module. A real implementation will use Protocol
  datagrams to walk the ring, but for now we simply echo the provided
  configuration so the higher layers can be exercised in isolation.
  """

  @spec run(map()) :: {:ok, list()} | {:error, term()}
  def run(%{devices: devices}) when is_list(devices) do
    {:ok, devices}
  end

  def run(_), do: {:error, :invalid_config}
end
