defmodule EtherCAT.Runtime do
  @moduledoc """
  Host-supervised singleton runtime for EtherCAT.

  Start this supervisor under the host application's supervision tree before
  calling `EtherCAT.start/1`. It owns the singleton registries, dynamic
  supervisors, and master process used by the public `EtherCAT` API.

  EtherCAT no longer starts itself as an OTP application. The supported model
  is for the host application to supervise `EtherCAT.Runtime` directly, either
  statically or via `DynamicSupervisor.start_child/2`.

  Example:

  ```elixir
  children = [
    {EtherCAT.Runtime, []}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)

  :ok = EtherCAT.start(backend: {:raw, %{interface: "eth0"}})
  ```

  Only one EtherCAT runtime may be active per BEAM node. The master and its
  supporting registries keep their singleton process names.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    Supervisor.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(:ok) do
    registry = Registry
    dynamic_supervisor = DynamicSupervisor

    children = [
      {registry, keys: :unique, name: EtherCAT.Registry},
      {registry, keys: :duplicate, name: EtherCAT.SubscriptionRegistry},
      {dynamic_supervisor, name: EtherCAT.SlaveSupervisor, strategy: :one_for_one},
      {dynamic_supervisor, name: EtherCAT.SessionSupervisor, strategy: :one_for_one},
      EtherCAT.Master
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
