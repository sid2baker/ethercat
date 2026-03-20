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
  - `EtherCAT.Simulator.Driver` for simulator/capture identity metadata

  Normal applications should not call this module at runtime. Use it to define
  drivers that plug into the EtherCAT runtime directly.
  """

  alias EtherCAT.Slave.ProcessData.Signal

  @type signal_name :: atom()
  @type config :: map()
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

  @callback encode_signal(signal_name(), config(), term()) :: binary()
  @callback decode_signal(signal_name(), config(), binary()) :: term()
  @callback init(config()) :: {:ok, term()} | {:error, term()}

  @callback project_state(decoded_inputs(), projected_state() | nil, term(), config()) ::
              {:ok, projected_state(), term(), [notice()], [term()]} | {:error, term()}

  @callback command(command_request(), projected_state(), term(), config()) ::
              {:ok, [output_intent()], term(), [notice()]} | {:error, term()}

  @callback describe(config()) :: description()

  @optional_callbacks [
    init: 1,
    describe: 1
  ]

  @spec unsupported_command(command_request()) :: {:error, {:unsupported_command, atom()}}
  def unsupported_command(%{name: name}) when is_atom(name),
    do: {:error, {:unsupported_command, name}}
end
