defmodule EtherCAT.DC.API do
  @moduledoc """
  Public facade for one-time DC initialization and runtime DC status calls.

  This module keeps synchronous wrappers and initialization entry points out of
  `EtherCAT.DC` so the runtime module can stay focused on its running state.
  """

  alias EtherCAT.Bus
  alias EtherCAT.DC
  alias EtherCAT.DC.Init
  alias EtherCAT.DC.Runtime

  @spec initialize_clocks(Bus.server(), [{non_neg_integer(), binary()}]) ::
          {:ok, non_neg_integer(), [non_neg_integer()]} | {:error, term()}
  def initialize_clocks(bus, slave_topology), do: Init.initialize_clocks(bus, slave_topology)

  @spec status(DC.server()) :: EtherCAT.DC.Status.t() | {:error, :not_running}
  def status(server \\ DC) do
    try do
      :gen_statem.call(server, :status)
    catch
      :exit, _reason -> {:error, :not_running}
    end
  end

  @spec await_locked(DC.server(), pos_integer()) :: :ok | {:error, term()}
  def await_locked(server \\ DC, timeout_ms \\ 5_000)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    Runtime.await_locked(server, timeout_ms, &status/1)
  end
end
