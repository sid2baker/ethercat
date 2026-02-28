defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Behaviour for slave-specific drivers.

  A driver is a pure module — no process state, no `Application.get_env`.
  All configuration is passed as a `config` map from `Master.start/1`.

  ## Profile format

  `process_data_profile/1` returns a map keyed by PDO name (atom). Each value
  names the SM index to use; the master reads physical params (address, size,
  ctrl byte) from the slave's own SII EEPROM category 0x0029.

      %{
        channels: %{sm_index: 0}
      }

  The SM ctrl byte from SII determines direction automatically:
  - bits[3:2] = `00` → ECAT reads → TxPDO (`:input`)
  - bits[3:2] = `01` → ECAT writes → RxPDO (`:output`)

  ## Optional keys

  ### `:size` — override SM DefaultSize (dynamic PDO remapping)

  When a slave supports dynamic PDO remapping via CoE (SII DefaultSize = 0),
  specify the expected size after the `sdo_config/1` SDO writes complete:

      %{custom_pdo: %{sm_index: 2, size: 6}}

  ### `:fmmu_offset` + `:size` — split-SM pattern

  Map two independent PDO names to sub-regions of one SM buffer. Useful when
  different processes subscribe to different channels independently:

      %{
        ch1: %{sm_index: 3, fmmu_offset: 0, size: 4},
        ch2: %{sm_index: 3, fmmu_offset: 4, size: 4}
      }

  When `fmmu_offset` is present, the SM register always uses the full SII DefaultSize.
  Only the FMMU is narrowed to the `{offset, size}` sub-region.

  ## Encode / decode

  Callbacks receive the PDO name and config for context:

      def encode_outputs(:outputs, _config, channels), do: <<channels::16-little>>
      def decode_inputs(:channels, _config, <<v::16-little>>), do: v

  ## Example — EL1809 (16-ch digital input)

      defmodule MyApp.EL1809 do
        @behaviour EtherCAT.Slave.Driver

        @impl true
        def process_data_profile(_config) do
          %{channels: %{sm_index: 0}}
        end

        @impl true
        def encode_outputs(_pdo, _config, _value), do: <<>>

        @impl true
        def decode_inputs(:channels, _config, <<v::16-little>>), do: v
        def decode_inputs(_pdo, _config, _), do: nil
      end

  ## Example — EL3202 (2-ch PT100 input, CoE slave)

      defmodule MyApp.EL3202 do
        @behaviour EtherCAT.Slave.Driver

        @impl true
        def process_data_profile(_config) do
          # SM3 = TxPDO; physical address and size come from SII EEPROM
          %{temperatures: %{sm_index: 3}}
        end

        @impl true
        def encode_outputs(_pdo, _config, _value), do: <<>>

        @impl true
        def decode_inputs(:temperatures, _config, <<
              _::1, error1::1, limit2_1::2, limit1_1::2, overrange1::1, underrange1::1,
              toggle1::1, state1::1, _::6, ch1::16-little-signed,
              _::1, error2::1, limit2_2::2, limit1_2::2, overrange2::1, underrange2::1,
              toggle2::1, state2::1, _::6, ch2::16-little-signed>>) do
          {
            %{value: ch1 / 10.0, underrange: underrange1 == 1, overrange: overrange1 == 1,
              limit1: limit1_1, limit2: limit2_1, error: error1 == 1,
              invalid: state1 == 1, toggle: toggle1},
            %{value: ch2 / 10.0, underrange: underrange2 == 1, overrange: overrange2 == 1,
              limit1: limit1_2, limit2: limit2_2, error: error2 == 1,
              invalid: state2 == 1, toggle: toggle2}
          }
        end
        def decode_inputs(_pdo, _config, _), do: nil
      end
  """

  @type pdo_name :: atom()
  @type config :: map()

  @type dc_config :: %{sync0_pulse_ns: pos_integer()}

  @type pdo_spec :: %{
          required(:sm_index) => non_neg_integer(),
          # Override SM register length — for dynamic PDO remapping (SII DefaultSize = 0).
          # Also used as FMMU length when :fmmu_offset is absent.
          # Use case: digital I/O slaves whose SII DefaultSize is 1 per SM byte but the
          # PDO spans multiple bytes (e.g. EL2809 16-ch output: sm_index: 0, size: 2).
          optional(:size) => pos_integer(),
          # Byte offset into SM buffer for this PDO's FMMU — split-SM pattern.
          # When present, SM register always uses SII DefaultSize; only FMMU is narrowed.
          # :size is required when :fmmu_offset is set.
          optional(:fmmu_offset) => non_neg_integer(),
          optional(:dc) => dc_config()
        }

  @doc "Return the SM hardware profile for each PDO, keyed by PDO name."
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

  @doc """
  Return a list of SDO writes to perform in PreOp before SM/FMMU configuration.

  Each entry is `{index, subindex, value, size}` where `size` is in bytes (1, 2, or 4).
  The slave executes them via CoE expedited SDO download. Failures are logged as warnings
  but do not prevent the slave from advancing to SafeOp/Op.

  SDO writes run before SM and FMMU registers are written, so this callback can perform
  dynamic PDO remapping (writing to 0x1C12/0x1C13) and the process_data_profile will
  reflect the resulting SM layout.
  """
  @callback sdo_config(config()) ::
              [{index :: integer(), subindex :: integer(), value :: integer(), size :: 1 | 2 | 4}]

  @optional_callbacks [on_preop: 2, on_safeop: 2, on_op: 2, sdo_config: 1]
end
