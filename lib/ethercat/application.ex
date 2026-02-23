defmodule Ethercat.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Ethercat.Registry},
      {Registry, keys: :duplicate, name: Ethercat.SignalRegistry},
      {Ethercat.TransportSupervisor, []},
      {Ethercat.MasterSupervisor, []}
    ]

    opts = [strategy: :one_for_one, name: Ethercat.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
