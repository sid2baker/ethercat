defmodule EtherCAT.Simulator.Driver do
  @moduledoc """
  Optional simulator/capture identity extension for real EtherCAT drivers.

  Drivers that expose stable vendor/product metadata for simulator hydration or
  generated capture scaffolds may implement this behaviour alongside
  `EtherCAT.Driver`.
  """

  @type identity :: %{
          required(:vendor_id) => non_neg_integer(),
          required(:product_code) => non_neg_integer(),
          optional(:revision) => non_neg_integer() | :any
        }

  @callback identity() :: identity() | nil

  @spec identity(module()) :: identity() | nil
  def identity(driver) when is_atom(driver) do
    if exported?(driver, :identity, 0) do
      driver
      |> apply(:identity, [])
      |> normalize_identity()
    else
      nil
    end
  end

  defp normalize_identity(nil), do: nil

  defp normalize_identity(%{vendor_id: vendor_id, product_code: product_code} = identity)
       when is_integer(vendor_id) and vendor_id >= 0 and is_integer(product_code) and
              product_code >= 0 do
    Map.put_new(identity, :revision, :any)
  end

  defp exported?(module, function_name, arity)
       when is_atom(module) and is_atom(function_name) and is_integer(arity) and arity >= 0 do
    Code.ensure_loaded?(module) and function_exported?(module, function_name, arity)
  end
end
