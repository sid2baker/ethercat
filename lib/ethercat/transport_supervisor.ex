defmodule Ethercat.TransportSupervisor do
  @moduledoc false

  use Supervisor

  @impl true
  def init(_arg) do
    children = [
      {Ethercat.Protocol.Transport, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end
end
