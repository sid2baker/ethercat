defmodule EtherCAT.TestSupport.RuntimeHelper do
  @moduledoc false

  @spec ensure_started!() :: :ok
  def ensure_started! do
    case Process.whereis(EtherCAT.Master) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case EtherCAT.Runtime.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to start EtherCAT.Runtime: #{inspect(reason)}"
        end
    end
  end
end
