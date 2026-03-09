defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Behaviour for slave-specific drivers.

  A driver is a pure module — no process state, no `Application.get_env`.
  All configuration is passed as a `config` map from `Master.start/1`.

  If a slave config omits `:driver`, `EtherCAT.Slave.Driver.Default` is used.
  That default driver exposes no PDO profile and is intended for couplers or
  dynamically configured devices.

  Generic SYNC0/SYNC1/latch intent does not live in the driver. It belongs on
  `%EtherCAT.Slave.Config{sync: %EtherCAT.Slave.Sync.Config{...}}`. Drivers only own
  device-specific translation through the optional `sync_mode/2` callback when a
  slave application needs additional mailbox objects beyond the generic ESC DC
  registers.

  ## Process-data model

  `process_data_model/1` returns a keyword list of `{signal_name, declaration}` pairs.
  Each value declares where that signal lives in the slave's PDO layout:

  - an integer means "this signal spans the whole PDO at that index"
  - `%EtherCAT.Slave.ProcessData.Signal{}` may select a bit-range inside a PDO

  The master reads SII EEPROM categories 0x0032 (TxPDO) and 0x0033 (RxPDO) to
  derive SyncManager assignment, direction, total SM size, and each PDO's bit
  offset within its SyncManager. The driver's signal model sits on top of that
  hardware description and names the application-facing signals.

  Use a keyword list (not a map) so signal order is explicit and deterministic.

      [channels: 0x1A00]

  Each signal is encoded and decoded independently. Sub-byte signals (e.g. 1-bit
  digital channels) receive/return 1 padded byte with the value in bit 0 (LSB).
  Larger signals receive exactly enough bytes to carry the declared `bit_size`.

  ## Example — EL1809 (16-ch digital input, 16 × 1-bit TxPDOs)

      defmodule MyApp.EL1809 do
        @behaviour EtherCAT.Slave.Driver

        @impl true
        def process_data_model(_config) do
          [
            ch1:  0x1A00, ch2:  0x1A01, ch3:  0x1A02, ch4:  0x1A03,
            ch5:  0x1A04, ch6:  0x1A05, ch7:  0x1A06, ch8:  0x1A07,
            ch9:  0x1A08, ch10: 0x1A09, ch11: 0x1A0A, ch12: 0x1A0B,
            ch13: 0x1A0C, ch14: 0x1A0D, ch15: 0x1A0E, ch16: 0x1A0F
          ]
        end

        @impl true
        def encode_signal(_signal, _config, _value), do: <<>>

        @impl true
        # 1-bit signal: the runtime extracts one bit and pads it into bit 0.
        def decode_signal(_ch, _config, <<_::7, bit::1>>), do: bit
        def decode_signal(_signal, _config, _), do: 0
      end

  ## Example — EL2809 (16-ch digital output, 16 × 1-bit RxPDOs)

      defmodule MyApp.EL2809 do
        @behaviour EtherCAT.Slave.Driver

        @impl true
        def process_data_model(_config) do
          [
            ch1:  0x1600, ch2:  0x1601, ch3:  0x1602, ch4:  0x1603,
            ch5:  0x1604, ch6:  0x1605, ch7:  0x1606, ch8:  0x1607,
            ch9:  0x1608, ch10: 0x1609, ch11: 0x160A, ch12: 0x160B,
            ch13: 0x160C, ch14: 0x160D, ch15: 0x160E, ch16: 0x160F
          ]
        end

        @impl true
        # 1-bit signal: return 1 byte; bit 0 is written into the correct SM bit.
        def encode_signal(_ch, _config, v), do: <<v::8>>

        @impl true
        def decode_signal(_signal, _config, _), do: nil
      end

  ## Example — EL3202 (2-ch PT100 input, 2 × 32-bit TxPDOs)

      defmodule MyApp.EL3202 do
        @behaviour EtherCAT.Slave.Driver

        @impl true
        def process_data_model(_config) do
          # 0x1A00 = channel 1 (SM3, bytes 0–3), 0x1A01 = channel 2 (SM3, bytes 4–7)
          [channel1: 0x1A00, channel2: 0x1A01]
        end

        @impl true
        def mailbox_config(_config) do
          [
            {:sdo_download, 0x8000, 0x19, <<8::16-little>>},
            {:sdo_download, 0x8010, 0x19, <<8::16-little>>}
          ]
        end

        @impl true
        def encode_signal(_signal, _config, _value), do: <<>>

        @impl true
        def decode_signal(:channel1, _config, <<
              _::1, error::1, _::2, _::2, overrange::1, underrange::1,
              toggle::1, state::1, _::6, value::16-little>>) do
          %{ohms: value / 16.0, overrange: overrange == 1, underrange: underrange == 1,
            error: error == 1, invalid: state == 1, toggle: toggle}
        end
        def decode_signal(:channel2, _config, <<
              _::1, error::1, _::2, _::2, overrange::1, underrange::1,
              toggle::1, state::1, _::6, value::16-little>>) do
          %{ohms: value / 16.0, overrange: overrange == 1, underrange: underrange == 1,
            error: error == 1, invalid: state == 1, toggle: toggle}
        end
        def decode_signal(_signal, _config, _), do: nil
      end
  """

  alias EtherCAT.Slave.ProcessData.Signal
  alias EtherCAT.Slave.Sync.Config, as: SyncConfig

  @type signal_name :: atom()
  @type config :: map()

  @type latch_edge :: :pos | :neg

  @type mailbox_step ::
          {:sdo_download, index :: non_neg_integer(), subindex :: non_neg_integer(),
           data :: binary()}

  @doc """
  Return the driver's logical signal model.

  Each signal maps to either a whole PDO index or a `%Signal{}` slice.

  An optional 2-arity version `process_data_model/2` receives the SII PDO configs
  as its second argument. When exported, the runtime calls it instead of `/1`, giving
  the driver access to hardware layout for dynamic model generation. The `Default`
  driver uses this to auto-discover all PDOs without any hand-written mapping.
  """
  @callback process_data_model(config()) ::
              [{signal_name(), non_neg_integer() | Signal.t()}]

  @doc """
  Optional 2-arity variant of `process_data_model/1` that receives SII PDO configs.

  Each entry in `sii_pdo_configs` is a map with keys:
    - `:index` — PDO object index (e.g. `0x1A00`)
    - `:direction` — `:input` or `:output`
    - `:sm_index` — SyncManager index
    - `:bit_size` — total PDO size in bits
    - `:bit_offset` — PDO offset within its SyncManager image in bits

  When this callback is exported, it takes precedence over `process_data_model/1`.
  """
  @callback process_data_model(config(), sii_pdo_configs :: [map()]) ::
              [{signal_name(), non_neg_integer() | Signal.t()}]

  @doc "Encode one logical output signal into raw bytes for the process image."
  @callback encode_signal(signal_name(), config(), term()) :: binary()

  @doc "Decode raw input bytes for one logical signal from the process image."
  @callback decode_signal(signal_name(), config(), binary()) :: term()

  @doc "Called on entry to PreOp state. Optional."
  @callback on_preop(slave_name :: atom(), config()) :: :ok

  @doc "Called on entry to SafeOp state. Optional."
  @callback on_safeop(slave_name :: atom(), config()) :: :ok

  @doc "Called on entry to Op state. Optional."
  @callback on_op(slave_name :: atom(), config()) :: :ok

  @doc """
  Return PREOP mailbox configuration steps.

  Currently the runtime supports `{:sdo_download, index, subindex, data}` steps.
  They execute in order before SyncManager/FMMU configuration, so this callback
  can perform dynamic PDO remapping (`0x1600+`, `0x1A00+`, `0x1C12`, `0x1C13`)
  or any other CoE parameterization required before SAFEOP.

  `data` may be any non-empty binary. The runtime selects expedited or
  segmented CoE transfer mode automatically.
  """
  @callback mailbox_config(config()) :: [mailbox_step()]

  @doc """
  Translate public sync intent into device-specific PREOP mailbox steps.

  Use this for slaves that need object-dictionary sync-mode configuration
  (for example `0x1C32` / `0x1C33`) in addition to the generic ESC SYNC setup
  handled by the runtime.

  `EtherCAT.Slave.Sync.CoE` provides helpers for the common synchronization mode and
  cycle-time objects when a driver wants to avoid hand-writing raw SDO tuples.
  """
  @callback sync_mode(config(), SyncConfig.t()) :: [mailbox_step()]

  @doc """
  Called when an ESC hardware LATCH event is captured during Op.

  `timestamp_ns` is DC system time in ns since 2000-01-01.
  """
  @callback on_latch(atom(), config(), 0 | 1, latch_edge(), non_neg_integer()) :: :ok

  @optional_callbacks [
    process_data_model: 2,
    on_preop: 2,
    on_safeop: 2,
    on_op: 2,
    mailbox_config: 1,
    sync_mode: 2,
    on_latch: 5
  ]
end
