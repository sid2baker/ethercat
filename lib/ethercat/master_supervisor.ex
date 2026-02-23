defmodule Ethercat.MasterSupervisor do
  @moduledoc false

  use Supervisor

  @impl true
  def init(_arg) do
    children = [
      {DynamicSupervisor, name: Ethercat.SlaveSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Ethercat.DomainSupervisor, strategy: :one_for_one},
      Ethercat.Master
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end
end
