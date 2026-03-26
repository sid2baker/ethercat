defmodule EtherCAT.Driver do
  @moduledoc """
  Public core extension API for slave drivers.

  A core driver owns four things:

  - logical PDO layout
  - raw value encoding and decoding
  - projected state
  - specialist command planning

  The runtime derives normal `:signal_changed` events by diffing the retained
  projected state image. Drivers should return projected state, faults, and any
  notices emitted through `EtherCAT.subscribe/2`.

  Specialist concerns live on separate behaviours:

  - `EtherCAT.Driver.Provisioning` for mailbox startup/setup steps
  - `EtherCAT.Driver.Latch` for DC latch callbacks
  - `EtherCAT.Simulator.Adapter` for simulator-side companion definitions

  Drivers may also implement optional `identity/0` metadata for simulator
  hydration and generated capture scaffolds.

  Normal applications should not call this module at runtime. Use it to define
  drivers that plug into the EtherCAT runtime directly.
  """

  alias EtherCAT.Slave.ProcessData.Signal

  @type signal_name :: atom()
  @type config :: map()
  @type identity :: %{
          required(:vendor_id) => non_neg_integer(),
          required(:product_code) => non_neg_integer(),
          optional(:revision) => non_neg_integer() | :any
        }
  @type decoded_inputs :: %{optional(atom()) => term()}
  @type projected_state :: %{optional(atom()) => term()}
  @type notice :: term()
  @type command_request :: %{
          required(:ref) => reference(),
          required(:name) => atom(),
          required(:args) => map()
        }
  @type output_intent :: {:write, signal_name(), term()}

  @type description :: %{
          optional(:device_type) => atom(),
          optional(:capabilities) => [atom()]
        }

  @callback signal_model(config(), sii_pdo_configs :: [map()]) ::
              [{signal_name(), non_neg_integer() | Signal.t()}]

  @callback identity() :: identity() | nil
  @callback encode_signal(signal_name(), config(), term()) :: binary()
  @callback decode_signal(signal_name(), config(), binary()) :: term()
  @callback init(config()) :: {:ok, term()} | {:error, term()}

  @callback project_state(decoded_inputs(), projected_state() | nil, term(), config()) ::
              {:ok, projected_state(), term(), [notice()], [term()]} | {:error, term()}

  @callback command(command_request(), projected_state(), term(), config()) ::
              {:ok, [output_intent()], term(), [notice()]} | {:error, term()}

  @callback describe(config()) :: description()

  @optional_callbacks [
    identity: 0,
    init: 1,
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

  @spec unsupported_command(command_request()) :: {:error, {:unsupported_command, atom()}}
  def unsupported_command(%{name: name}) when is_atom(name),
    do: {:error, {:unsupported_command, name}}

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
