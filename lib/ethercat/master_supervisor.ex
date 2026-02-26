defmodule EtherCAT.MasterSupervisor do
  @moduledoc false

  use Supervisor

  @impl true
  def init(_arg) do
    children = [
      {DynamicSupervisor, name: EtherCAT.SlaveSupervisor, strategy: :one_for_one},
      EtherCAT.Master,
      EtherCAT.DomainSupervisor
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end
end
