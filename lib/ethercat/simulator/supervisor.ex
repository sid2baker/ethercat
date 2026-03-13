defmodule EtherCAT.Simulator.Supervisor do
  @moduledoc false

  use Supervisor

  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.RawSocket
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
    Supervisor.init(children(opts), strategy: :one_for_one)
  end

  defp children(opts) do
    simulator_opts = Keyword.drop(opts, [:udp, :raw])

    [simulator_child(simulator_opts)] ++
      maybe_udp_child(Keyword.get(opts, :udp)) ++
      maybe_raw_child(Keyword.get(opts, :raw))
  end

  defp simulator_child(opts) do
    Supervisor.child_spec({Simulator, opts}, start: {Simulator, :start_link, [opts]})
  end

  defp maybe_udp_child(nil), do: []
  defp maybe_udp_child(udp_opts) when is_list(udp_opts), do: [{Udp, udp_opts}]

  defp maybe_raw_child(nil), do: []
  defp maybe_raw_child(raw_opts) when is_list(raw_opts), do: [{RawSocket, raw_opts}]
end
