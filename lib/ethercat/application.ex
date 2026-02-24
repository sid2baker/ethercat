defmodule EtherCAT.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: EtherCAT.Registry},
      {Registry, keys: :duplicate, name: EtherCAT.SignalRegistry},
      {EtherCAT.MasterSupervisor, []}
    ]

    opts = [strategy: :one_for_one, name: EtherCAT.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
