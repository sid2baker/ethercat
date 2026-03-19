defmodule EtherCAT.Simulator.Transport.Raw do
  @moduledoc """
  Public raw transport surface for `EtherCAT.Simulator`.

  Raw transport runs one primary endpoint in single-link mode or paired
  primary/secondary endpoints in redundant mode. This module exposes raw-edge
  transport controls and mode-aware introspection without leaking the endpoint
  worker module into public tests and tooling.
  """

  alias EtherCAT.Simulator.Transport.Raw.{Endpoint, Fault}

  @type endpoint_selector :: :primary | :secondary | :all
  @type ingress_selector :: :primary | :secondary | :all
  @type fault :: {:delay_response, endpoint_selector(), non_neg_integer(), ingress_selector()}

  @spec info() :: {:ok, map()} | {:error, :not_found}
  def info do
    with {:ok, endpoints} <- Endpoint.infos() do
      {:ok, Map.put(endpoints, :mode, mode_for(endpoints))}
    end
  end

  @spec inject_fault(Fault.t() | fault()) :: :ok | {:error, :invalid_fault | :not_found}
  def inject_fault(fault) do
    with {:ok, normalized_fault} <- Fault.normalize(fault),
         {:ok, endpoint_faults} <- normalize_endpoint_faults(normalized_fault) do
      apply_endpoint_faults(endpoint_faults)
    else
      :error -> {:error, :invalid_fault}
      {:error, _reason} = error -> error
    end
  end

  @spec clear_faults() :: :ok | {:error, :not_found}
  def clear_faults do
    with {:ok, endpoints} <- Endpoint.infos() do
      endpoints
      |> Map.keys()
      |> Enum.map(fn ingress -> Endpoint.endpoint_name(ingress) end)
      |> apply_endpoint_faults()
    end
  end

  defp normalize_endpoint_faults({:delay_response, selector, delay_ms, from_ingress})
       when selector in [:primary, :secondary, :all] and is_integer(delay_ms) and delay_ms >= 0 and
              from_ingress in [:all, :primary, :secondary] do
    with {:ok, endpoints} <- Endpoint.infos(),
         {:ok, selected_ingresses} <- select_ingresses(endpoints, selector) do
      {:ok,
       Enum.map(selected_ingresses, fn ingress ->
         {Endpoint.endpoint_name(ingress), delay_ms, from_ingress}
       end)}
    end
  end

  defp normalize_endpoint_faults(_fault), do: {:error, :invalid_fault}

  defp select_ingresses(endpoints, :all), do: {:ok, Map.keys(endpoints)}

  defp select_ingresses(endpoints, selector) do
    if Map.has_key?(endpoints, selector) do
      {:ok, [selector]}
    else
      {:error, :invalid_fault}
    end
  end

  defp apply_endpoint_faults(endpoint_faults) do
    Enum.reduce_while(endpoint_faults, :ok, fn
      {name, delay_ms, from_ingress}, :ok ->
        case Endpoint.set_response_delay_fault(name, delay_ms, from_ingress) do
          :ok -> {:cont, :ok}
          {:error, :not_found} = error -> {:halt, error}
        end

      name, :ok ->
        case Endpoint.clear_response_delay_fault(name) do
          :ok -> {:cont, :ok}
          {:error, :not_found} = error -> {:halt, error}
        end
    end)
  end

  defp mode_for(endpoints) do
    if map_size(endpoints) == 1, do: :single, else: :redundant
  end
end
