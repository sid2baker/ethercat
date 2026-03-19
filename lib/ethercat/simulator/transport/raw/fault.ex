defmodule EtherCAT.Simulator.Transport.Raw.Fault do
  @moduledoc """
  Builder API for `EtherCAT.Simulator.Transport.Raw.inject_fault/1`.

  Raw transport faults model behavior at the raw-wire endpoint boundary, not at
  the simulator core. They are mode-aware: single-link raw only exposes the
  primary endpoint, while redundant raw can target both primary and secondary
  endpoints independently.

  Typical usage:

      alias EtherCAT.Simulator.Transport.Raw
      alias EtherCAT.Simulator.Transport.Raw.Fault

      Raw.inject_fault(Fault.delay_response(200))
      Raw.inject_fault(Fault.delay_response(200, endpoint: :secondary, from_ingress: :primary))
      Fault.describe(Fault.delay_response(50, endpoint: :primary, from_ingress: :secondary))
  """

  @type endpoint_selector :: :primary | :secondary | :all
  @type from_ingress :: :primary | :secondary | :all
  @type t :: %__MODULE__{
          kind: :delay_response,
          endpoint: endpoint_selector(),
          delay_ms: non_neg_integer(),
          from_ingress: from_ingress()
        }

  defstruct kind: :delay_response,
            endpoint: :all,
            delay_ms: 0,
            from_ingress: :all

  @spec delay_response(non_neg_integer(), keyword()) :: t()
  def delay_response(delay_ms, opts \\ [])
      when is_integer(delay_ms) and delay_ms >= 0 do
    %__MODULE__{
      endpoint: Keyword.get(opts, :endpoint, :all),
      delay_ms: delay_ms,
      from_ingress: Keyword.get(opts, :from_ingress, :all)
    }
  end

  @spec normalize(t() | EtherCAT.Simulator.Transport.Raw.fault()) ::
          {:ok, EtherCAT.Simulator.Transport.Raw.fault()} | :error
  def normalize(%__MODULE__{
        kind: :delay_response,
        endpoint: endpoint,
        delay_ms: delay_ms,
        from_ingress: from_ingress
      })
      when endpoint in [:primary, :secondary, :all] and is_integer(delay_ms) and delay_ms >= 0 and
             from_ingress in [:primary, :secondary, :all] do
    {:ok, {:delay_response, endpoint, delay_ms, from_ingress}}
  end

  def normalize(%__MODULE__{}), do: :error
  def normalize(raw_fault), do: {:ok, raw_fault}

  @spec describe(t() | EtherCAT.Simulator.Transport.Raw.fault()) :: String.t()
  def describe(%__MODULE__{} = fault) do
    case normalize(fault) do
      {:ok, raw_fault} -> describe(raw_fault)
      :error -> inspect(fault)
    end
  end

  def describe({:delay_response, endpoint, delay_ms, from_ingress})
      when endpoint in [:primary, :secondary, :all] and is_integer(delay_ms) and delay_ms >= 0 and
             from_ingress in [:primary, :secondary, :all] do
    "delay #{endpoint_label(endpoint)} raw responses from #{from_ingress} ingress by #{delay_ms}ms"
  end

  def describe(other), do: inspect(other)

  defp endpoint_label(:all), do: "all"
  defp endpoint_label(endpoint), do: Atom.to_string(endpoint)
end
