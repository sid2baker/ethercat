defmodule EtherCAT.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: EtherCAT.Registry},
      {DynamicSupervisor, name: EtherCAT.SlaveSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: EtherCAT.DomainSupervisor, strategy: :one_for_one},
      EtherCAT.Master
    ]

    opts = [strategy: :one_for_all, name: EtherCAT.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
