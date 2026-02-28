defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Behaviour for slave-specific drivers.

  A driver is a pure module — no process state, no `Application.get_env`.
  All configuration is passed as a `config` map from `Master.start/1`.

  ## Profile format

  `process_data_profile/1` returns a map keyed by PDO name (atom) with values
  being the SII PDO object index (integer). The master reads SII EEPROM categories
  0x0032 (TxPDO) and 0x0033 (RxPDO) to auto-derive: SM assignment, direction,
  total SM size, and per-PDO bit offset within the SM.

      %{
        channels: 0x1A00
      }

  Each named PDO gets its own FMMU (with bit-level precision for sub-byte PDOs).
  `decode_inputs`/`encode_outputs` are called once per named PDO with that PDO's
  exact bytes. Sub-byte PDOs (e.g. 1-bit channels) receive/return 1 padded byte
  with the value in bit 0 (LSB).

  ## Example — EL1809 (16-ch digital input, 16 × 1-bit TxPDOs)

      defmodule MyApp.EL1809 do
        @behaviour EtherCAT.Slave.Driver

        @impl true
        def process_data_profile(_config) do
          %{
            ch1:  0x1A00, ch2:  0x1A01, ch3:  0x1A02, ch4:  0x1A03,
            ch5:  0x1A04, ch6:  0x1A05, ch7:  0x1A06, ch8:  0x1A07,
            ch9:  0x1A08, ch10: 0x1A09, ch11: 0x1A0A, ch12: 0x1A0B,
            ch13: 0x1A0C, ch14: 0x1A0D, ch15: 0x1A0E, ch16: 0x1A0F
          }
        end

        @impl true
        def encode_outputs(_pdo, _config, _value), do: <<>>

        @impl true
        # 1-bit PDO: FMMU maps the physical SM bit to logical bit 0.
        # decode_inputs receives 1 byte; bit 0 (LSB) is the channel value.
        def decode_inputs(_ch, _config, <<_::7, bit::1>>), do: bit
        def decode_inputs(_pdo, _config, _), do: 0
      end

  ## Example — EL2809 (16-ch digital output, 16 × 1-bit RxPDOs)

      defmodule MyApp.EL2809 do
        @behaviour EtherCAT.Slave.Driver

        @impl true
        def process_data_profile(_config) do
          %{
            ch1:  0x1600, ch2:  0x1601, ch3:  0x1602, ch4:  0x1603,
            ch5:  0x1604, ch6:  0x1605, ch7:  0x1606, ch8:  0x1607,
            ch9:  0x1608, ch10: 0x1609, ch11: 0x160A, ch12: 0x160B,
            ch13: 0x160C, ch14: 0x160D, ch15: 0x160E, ch16: 0x160F
          }
        end

        @impl true
        # 1-bit PDO: return 1 byte; the FMMU places bit 0 into the correct SM bit.
        def encode_outputs(_ch, _config, v), do: <<v::8>>

        @impl true
        def decode_inputs(_pdo, _config, _), do: nil
      end

  ## Example — EL3202 (2-ch PT100 input, 2 × 32-bit TxPDOs)

      defmodule MyApp.EL3202 do
        @behaviour EtherCAT.Slave.Driver

        @impl true
        def process_data_profile(_config) do
          # 0x1A00 = channel 1 (SM3, bytes 0–3), 0x1A01 = channel 2 (SM3, bytes 4–7)
          %{channel1: 0x1A00, channel2: 0x1A01}
        end

        @impl true
        def sdo_config(_config) do
          [{0x8000, 0x19, 8, 2}, {0x8010, 0x19, 8, 2}]
        end

        @impl true
        def encode_outputs(_pdo, _config, _value), do: <<>>

        @impl true
        def decode_inputs(:channel1, _config, <<
              _::1, error::1, _::2, _::2, overrange::1, underrange::1,
              toggle::1, state::1, _::6, value::16-little>>) do
          %{ohms: value / 16.0, overrange: overrange == 1, underrange: underrange == 1,
            error: error == 1, invalid: state == 1, toggle: toggle}
        end
        def decode_inputs(:channel2, _config, <<
              _::1, error::1, _::2, _::2, overrange::1, underrange::1,
              toggle::1, state::1, _::6, value::16-little>>) do
          %{ohms: value / 16.0, overrange: overrange == 1, underrange: underrange == 1,
            error: error == 1, invalid: state == 1, toggle: toggle}
        end
        def decode_inputs(_pdo, _config, _), do: nil
      end
  """

  @type pdo_name :: atom()
  @type config :: map()

  @type dc_config :: %{sync0_pulse_ns: pos_integer()}

  @doc "Return a map of PDO name → SII PDO object index (e.g. 0x1A00)."
  @callback process_data_profile(config()) :: %{pdo_name() => non_neg_integer()}

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

  @doc """
  Return Distributed Clocks SYNC0 parameters, or `nil` to disable DC on this slave.

  Called during SafeOp entry when `dc_cycle_ns` is configured on the master.
  """
  @callback dc_config(config()) :: dc_config() | nil

  @optional_callbacks [on_preop: 2, on_safeop: 2, on_op: 2, sdo_config: 1, dc_config: 1]
end
