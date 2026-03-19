defmodule EtherCAT.Simulator.Supervisor do
  @moduledoc false

  use Supervisor

  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Transport.{Udp, Raw.Endpoint}

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

  defp maybe_raw_child(raw_opts) when is_list(raw_opts) do
    raw_opts
    |> normalize_raw_endpoints()
    |> Enum.map(fn {name, opts} ->
      {Endpoint, Keyword.put(opts, :name, name)}
    end)
  end

  defp normalize_raw_endpoints(raw_opts) do
    cond do
      Keyword.has_key?(raw_opts, :primary) or Keyword.has_key?(raw_opts, :secondary) ->
        []
        |> maybe_add_raw_endpoint(:primary, Keyword.get(raw_opts, :primary))
        |> maybe_add_raw_endpoint(:secondary, Keyword.get(raw_opts, :secondary))

      true ->
        [
          {Keyword.get(raw_opts, :name, Endpoint.endpoint_name(:primary)),
           Keyword.put(raw_opts, :ingress, :primary)}
        ]
    end
  end

  defp maybe_add_raw_endpoint(endpoints, _ingress, nil), do: endpoints

  defp maybe_add_raw_endpoint(endpoints, ingress, opts) when is_list(opts) do
    endpoints ++
      [
        {Endpoint.endpoint_name(ingress),
         opts
         |> Keyword.put(:ingress, ingress)}
      ]
  end
end
