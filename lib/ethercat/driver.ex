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
  - `EtherCAT.Simulator.Adapter` for simulator-side companion definitions

  Latch events are consumed through `EtherCAT.Signals` subscriptions.

  ## Codec contract

  Codec callbacks run inside the slave process and must be fast, pure functions.
  Return `{:error, reason}` for invalid values or undecodable data. Exceptions
  indicate driver bugs and are not converted to successful observations.

  Codecs receive or return byte-aligned binaries of `ceil(bit_size / 8)` bytes.
  Fields use EtherCAT little-endian bit order: bit zero is the least significant
  bit of the first byte. Unused high bits of the last byte must be zero. Signed
  and multi-byte values must be encoded explicitly by the driver.

  Implement only the codecs needed by the registered signal directions. The
  runtime checks those capabilities during PREOP configuration.

  `describe/1` supplies static metadata only; when absent, endpoints are empty.
  `signal_model/2` receives discovered PDOs and is never called to build a
  description. Return named `EtherCAT.Driver.Signal` structs for all mappings.

  Concrete device drivers are normally application-owned. This library ships
  the contract and a generic default driver, while sample device-specific
  drivers live in test support only.

  ## Share signal declarations

  Keep related device knowledge together without changing the callbacks. A
  private catalogue can pair each endpoint's metadata with its PDO mapping,
  then project the two views independently. For a device with two known one-bit
  input PDOs:

      defmodule MyApp.DigitalInputs do
        @behaviour EtherCAT.Driver

        alias EtherCAT.Driver.Signal
        alias EtherCAT.Endpoint

        @signals [
          {%Endpoint{signal: :ch1, direction: :input, type: :boolean},
           Signal.whole_pdo(0x1A00)},
          {%Endpoint{signal: :ch2, direction: :input, type: :boolean},
           Signal.whole_pdo(0x1A01)}
        ]

        @impl true
        def signal_model(_config, _pdos) do
          Enum.map(@signals, fn {endpoint, mapping} -> {endpoint.signal, mapping} end)
        end

        @impl true
        def describe(_config) do
          %{device_type: :digital_input, endpoints: Enum.map(@signals, &elem(&1, 0))}
        end

        @impl true
        def decode_signal(_signal, _config, <<0::7, bit::1>>), do: {:ok, bit == 1}
        def decode_signal(_signal, _config, _raw), do: {:error, :invalid_data}
      end

  For configurable devices, select the enabled rows in one private
  `catalogue(config)` function used by both callbacks. Descriptions must still
  work without discovery. Resolve discovery-dependent mappings in
  `c:signal_model/2`, not in `c:describe/1`, and do not silently omit an expected
  signal just because its PDO is missing: leave the mismatch visible to the
  runtime's mapping validation.

  This is an optional authoring pattern, not a new schema or codec DSL. Scalar
  types, bit widths, and discovered directions must still agree. If codecs look
  up catalogue rows on every call, measure that cost for your cycle budget;
  explicit codec clauses remain appropriate.

  The repository includes a
  [configurable mixed-PDO example](https://github.com/sid2baker/ethercat/blob/main/test/support/drivers/catalogue_example.ex),
  a [before/after comparison](https://github.com/sid2baker/ethercat/blob/main/test/ethercat/driver/catalogue_example_test.exs),
  and [trade-offs](https://github.com/sid2baker/ethercat/blob/main/test/support/drivers/catalogue_example.md).
  Run the comparison from a checkout with
  `mix test test/ethercat/driver/catalogue_example_test.exs`.
  """

  alias EtherCAT.Driver.Signal

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

  @doc """
  Map logical signal names to whole PDOs or bit slices within discovered PDOs.

  This is the only mandatory callback. Use the discovered `pdos` when the
  device's layout requires resolution; this callback declares mappings, not
  mailbox setup or live values. The runtime validates requested mappings against
  discovery before registering process data.
  """
  @callback signal_model(config(), pdos :: [EtherCAT.Driver.PDO.t()]) ::
              [{signal_name(), Signal.t()}]

  @doc """
  Declare the driver's vendor ID, product code, and optional revision.

  Omission or `nil` means no declared identity. `identity/1` defaults an omitted
  revision to `:any`. Simulator hydration uses this declaration for identity
  defaults; it does not by itself enforce a hardware compatibility check.
  """
  @callback identity() :: identity() | nil

  @doc """
  Encode one output signal value into its protocol bytes without transmitting it.

  Required only when registered signals include outputs. Follow the module's
  byte-width, padding, and little-endian contract. Return `{:error, reason}` for
  invalid values; failed encoding leaves the staged output unchanged.
  """
  @callback encode_signal(signal_name(), config(), term()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Decode one input signal's protocol bytes into an application value.

  Required only when registered signals include inputs. Return `{:error, reason}`
  for undecodable data rather than substituting a value. This converts an existing
  observation; it does not read from the bus.
  """
  @callback decode_signal(signal_name(), config(), binary()) :: {:ok, term()} | {:error, term()}

  @doc """
  Describe the configured device type and static signal endpoints without bus access.

  Optional; missing metadata defaults to no device type and an empty endpoint
  list. Use the same signal names as `c:signal_model/2`, but do not require
  discovery or live values to build the description.
  """
  @callback describe(config()) :: description()

  @optional_callbacks [
    encode_signal: 3,
    decode_signal: 3,
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
