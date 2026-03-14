defmodule EtherCAT.Utils do
  @moduledoc false

  @spec classify_call_exit(term(), term()) :: {:error, term()}
  def classify_call_exit({:timeout, _}, _missing_reason), do: {:error, :timeout}
  def classify_call_exit({:noproc, _}, missing_reason), do: {:error, missing_reason}
  def classify_call_exit({:normal, _}, missing_reason), do: {:error, missing_reason}

  def classify_call_exit({reason, {GenServer, :call, _call_args}}, _missing_reason),
    do: {:error, {:server_exit, reason}}

  def classify_call_exit(reason, _missing_reason), do: {:error, {:server_exit, reason}}
end
