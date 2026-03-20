defmodule EtherCAT.Raw do
  @moduledoc """
  Advanced raw-process-data access.

  `EtherCAT.Raw` bypasses the top-level driver-backed API and works directly
  with the registered PDO/latch model owned by the slave runtime. Most
  applications should use `EtherCAT.snapshot/0`, `EtherCAT.snapshot/1`,
  `EtherCAT.subscribe/2`, and `EtherCAT.command/3` instead.
  """

  alias EtherCAT.Slave

  @doc """
  Subscribe to one registered process-data signal or configured latch name.

  Signal updates arrive as `{:ethercat, :signal, slave_name, signal_name, value}`.
  Latch edges arrive as `{:ethercat, :latch, slave_name, latch_name, timestamp_ns}`.
  """
  @spec subscribe(atom(), atom(), pid()) ::
          :ok
          | {:error, {:not_registered, atom()} | :not_found | :timeout | {:server_exit, term()}}
  def subscribe(slave_name, signal_name, pid \\ self()) do
    Slave.subscribe(slave_name, signal_name, pid)
  end

  @doc """
  Stage one decoded output signal value into the next domain cycle.
  """
  @spec write_output(atom(), atom(), term()) :: :ok | {:error, term()}
  def write_output(slave_name, signal_name, value) do
    Slave.write_output(slave_name, signal_name, value)
  end

  @doc """
  Read one decoded input signal directly from the process image.
  """
  @spec read_input(atom(), atom()) :: {:ok, {term(), integer()}} | {:error, term()}
  def read_input(slave_name, signal_name) do
    Slave.read_input(slave_name, signal_name)
  end
end
