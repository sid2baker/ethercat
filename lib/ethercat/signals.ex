defmodule EtherCAT.Signals do
  @moduledoc """
  Session-bound signal and latch subscriptions.

  `EtherCAT.Signals` works directly with the registered PDO/latch model owned by
  the slave runtime. Most applications should use `EtherCAT.samples/2`,
  `EtherCAT.sample/3`, `EtherCAT.subscribe/3`, `EtherCAT.read/3`, and
  `EtherCAT.write/4` instead.
  """

  alias EtherCAT.Session
  alias EtherCAT.Slave

  @doc """
  Subscribe to one registered process-data signal or configured latch name.

  Signal updates arrive as `{:ethercat, :signal, slave_name, signal_name, value}`.
  Decode failures arrive as `{:ethercat, :signal_error, slave_name, signal_name, reason}`
  for each decoded input observation containing that failure, even if only another
  signal in the slave/domain image changed. Unchanged input images do not guarantee
  a new observation on every cycle.
  Latch edges arrive as `{:ethercat, :latch, slave_name, latch_name, timestamp_ns}`.

  These messages have no subscription reference or backpressure. Registrations
  last for the subscriber/slave process lifetime. Prefer `EtherCAT.subscribe/3`
  when you need cancellable, reference-scoped protocol observations.
  """
  @spec subscribe(Session.t(), atom(), atom(), pid()) :: :ok | {:error, term()}
  def subscribe(session, slave_name, signal_name, pid \\ self())
      when is_atom(slave_name) and is_atom(signal_name) and is_pid(pid) do
    with {:ok, slave} <- Session.slave(session, slave_name) do
      Slave.subscribe(slave, signal_name, pid)
    end
  end
end
