defmodule EtherCAT.Driver do
  @moduledoc """
  Public protocol/device driver boundary for EtherCAT slaves.

  A driver describes protocol-facing concerns only:

  - device identity
  - logical PDO signal layout
  - signal encoding and decoding
  - static signal metadata

  Semantic state projection, machine commands, and machine events do not belong
  in this behaviour. Those concerns should be implemented above EtherCAT by a
  semantic integration such as an `Entity.Provider` adapter.

  Specialist protocol concerns live on separate behaviours:

  - `EtherCAT.Driver.Provisioning` for mailbox startup/setup steps
  - `EtherCAT.Driver.Latch` for DC latch callbacks
  - `EtherCAT.Simulator.Adapter` for simulator-side companion definitions

  Concrete device drivers are normally application-owned. This library ships
  the contract and a generic default driver, while sample device-specific
  drivers live in test support only.
  """

  alias EtherCAT.Slave.ProcessData.Signal

  @type signal_name :: atom()
  @type config :: map()
  @type identity :: %{
          required(:vendor_id) => non_neg_integer(),
          required(:product_code) => non_neg_integer(),
          optional(:revision) => non_neg_integer() | :any
        }

  @type description :: %{
          optional(:device_type) => atom(),
          optional(:endpoints) => [EtherCAT.Endpoint.t() | map()]
        }

  @callback signal_model(config(), sii_pdo_configs :: [map()]) ::
              [{signal_name(), non_neg_integer() | Signal.t()}]

  @callback identity() :: identity() | nil
  @callback encode_signal(signal_name(), config(), term()) :: binary()
  @callback decode_signal(signal_name(), config(), binary()) :: term()
  @callback describe(config()) :: description()

  @optional_callbacks [
    identity: 0,
    describe: 1
  ]

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
