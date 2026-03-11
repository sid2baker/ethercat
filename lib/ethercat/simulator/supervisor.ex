defmodule EtherCAT.Simulator.Supervisor do
  @moduledoc false

  use Supervisor

  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Udp

  @name __MODULE__

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: @name,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: @name)

  @impl true
  def init(opts) do
    children =
      [
        {Simulator, opts_without_udp(opts)}
      ] ++ udp_children(opts)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp udp_children(opts) do
    case Keyword.get(opts, :udp) do
      nil ->
        []

      udp_opts when is_list(udp_opts) ->
        [{Udp, udp_opts}]
    end
  end

  defp opts_without_udp(opts), do: Keyword.drop(opts, [:udp])
end
