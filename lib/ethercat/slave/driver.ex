defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Behaviour for slave-specific drivers.

  A driver is a pure module — no process state, no `Application.get_env`.
  All configuration is passed as a `config` map from `Master.start/1`.

  ## Profile format

  `process_data_profile/1` returns a map keyed by PDO name (atom):

      %{
        channels: %{
          inputs_size:  2,
          outputs_size: 0,
          sms:          [{0, 0x1000, 2, 0x20}],
          fmmus:        [{0, 0x1000, 2, :read}]
        }
      }

  ## Encode / decode

  Callbacks receive the PDO name and config for context:

      def encode_outputs(:outputs, _config, channels), do: <<channels::16-little>>
      def decode_inputs(:channels, _config, <<v::16-little>>), do: v

  ## SM ctrl byte reference

  `sms` entries: `{sm_index, phys_start, length, ctrl}`

    - bits[1:0] mode: `0b00` buffered, `0b10` mailbox
    - bits[3:2] dir:  `0b00` ECAT reads (input), `0b01` ECAT writes (output)
    - bit[5]  AL event IRQ
    - bit[6]  watchdog trigger (set for output SMs)

  Common ctrl values: `0x20` inputs, `0x24` outputs, `0x44` outputs + WDT.

  `fmmus` entries: `{fmmu_index, phys_start, size, :read | :write}`
  `phys_start` must match the paired SM's start address.

  ## Example — EL1809 (16-ch digital input)

      defmodule MyApp.EL1809 do
        @behaviour EtherCAT.Slave.Driver

        @impl true
        def process_data_profile(_config) do
          %{
            channels: %{
              inputs_size:  2,
              outputs_size: 0,
              sms:   [{0, 0x1000, 2, 0x20}],
              fmmus: [{0, 0x1000, 2, :read}]
            }
          }
        end

        @impl true
        def encode_outputs(_pdo, _config, _value), do: <<>>

        @impl true
        def decode_inputs(:channels, _config, <<v::16-little>>), do: v
        def decode_inputs(_pdo, _config, _), do: nil
      end
  """

  @type pdo_name :: atom()
  @type config :: map()

  @type sm_config :: {
          index :: non_neg_integer(),
          phys_start :: non_neg_integer(),
          length :: non_neg_integer(),
          ctrl :: non_neg_integer()
        }

  @type fmmu_config :: {
          index :: non_neg_integer(),
          phys_start :: non_neg_integer(),
          size :: non_neg_integer(),
          type :: :read | :write
        }

  @type dc_config :: %{sync0_pulse_ns: pos_integer()}

  @type pdo_spec :: %{
          required(:inputs_size) => non_neg_integer(),
          required(:outputs_size) => non_neg_integer(),
          required(:sms) => [sm_config()],
          required(:fmmus) => [fmmu_config()],
          optional(:dc) => dc_config()
        }

  @doc "Return the SM/FMMU hardware profile for each PDO, keyed by PDO name."
  @callback process_data_profile(config()) :: %{pdo_name() => pdo_spec()}

  @doc "Encode a domain value into raw output bytes for the process image."
  @callback encode_outputs(pdo_name(), config(), term()) :: binary()

  @doc "Decode raw input bytes from the process image into a domain value."
  @callback decode_inputs(pdo_name(), config(), binary()) :: term()

  @doc "Called on entry to PreOp state. Optional."
  @callback on_preop(slave_name :: atom(), config()) :: :ok

  @doc "Called on entry to SafeOp state. Optional."
  @callback on_safeop(slave_name :: atom(), config()) :: :ok

  @doc "Called on entry to Op state. Optional."
  @callback on_op(slave_name :: atom(), config()) :: :ok

  @optional_callbacks [on_preop: 2, on_safeop: 2, on_op: 2]
end
