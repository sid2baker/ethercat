defmodule Ethercat.Bus do
  @moduledoc false

  alias Ethercat.Bus.Scanner

  defdelegate run_scanner(config), to: Scanner, as: :run

  @doc """
  Queues a write request. Real implementation pending.
  """
  def enqueue_write(_device, _signal, _value), do: {:error, :not_implemented}
end
