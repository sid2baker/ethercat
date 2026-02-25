defmodule EtherCAT do
  @moduledoc """
  Public entrypoint for the EtherCAT master runtime.

  Delegates to `EtherCAT.Master` and `EtherCAT.Slave`. The master is a
  singleton — no bus reference is needed in API calls.

  ## Quick start

      EtherCAT.start(interface: "eth0")
      EtherCAT.slaves()
      #=> [{0x1000, #PID<...>}, ...]

      EtherCAT.Slave.identity(0x1000)
      EtherCAT.go_operational()
  """

  alias EtherCAT.Master

  @doc "Start the master: open `interface`, scan, and start slave processes."
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: Master.start(opts)

  @doc "Stop the master: shut down all slaves and close the link."
  @spec stop() :: :ok
  def stop, do: Master.stop()

  @doc "Return `[{station, pid}]` for all discovered slaves."
  @spec slaves() :: [{non_neg_integer(), pid()}]
  def slaves, do: Master.slaves()

  @doc "Request all slaves transition to `:op`."
  @spec go_operational() :: :ok
  def go_operational, do: Master.go_operational()
end
