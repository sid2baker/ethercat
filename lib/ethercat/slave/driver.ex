defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Behaviour for slave-specific drivers.

  A driver declares the SM/FMMU hardware profile for a slave type and handles
  encoding output domain terms to raw binary and decoding raw binary inputs back
  to domain terms. The library handles all register I/O and the process image
  exchange; the driver owns data interpretation.

  ## Minimal example — 16-channel digital output (EL2809)

      defmodule MyApp.EL2809 do
        @behaviour EtherCAT.Slave.Driver

        @impl true
        def process_data_profile do
          %{
            outputs_size: 2,
            inputs_size: 0,
            sms:   [{2, 0x0F00, 2, 0x44}],
            fmmus: [{0, 0x0F00, 2, :write}]
          }
        end

        @impl true
        def encode_outputs(channels) when is_integer(channels),
          do: <<channels::16-little>>

        @impl true
        def decode_inputs(<<>>), do: nil
      end

  ## Minimal example — 16-channel digital input (EL1809)

      defmodule MyApp.EL1809 do
        @behaviour EtherCAT.Slave.Driver

        @impl true
        def process_data_profile do
          %{
            outputs_size: 0,
            inputs_size: 2,
            sms:   [{3, 0x1000, 2, 0x20}],
            fmmus: [{1, 0x1000, 2, :read}]
          }
        end

        @impl true
        def encode_outputs(_), do: <<>>

        @impl true
        def decode_inputs(<<channels::16-little>>), do: channels
      end

  ## SM/FMMU profile

  `sms` is a list of `{sm_index, phys_start, length, ctrl}` tuples.
  `ctrl` is the raw SM control byte:

    - bits [1:0] — mode: `0b00` = buffered (3-buffer), `0b10` = mailbox
    - bits [3:2] — direction: `0b00` = ECAT reads (input), `0b01` = ECAT writes (output)
    - bit [5]    — AL event interrupt enable
    - bit [6]    — watchdog trigger enable (set for output SMs)

  Common `ctrl` values:

    - `0x20` — buffered, ECAT reads inputs
    - `0x24` — buffered, ECAT writes outputs (with AL IRQ)
    - `0x44` — buffered, ECAT writes outputs (with AL IRQ + WDT trigger)

  `fmmus` is a list of `{fmmu_index, phys_start, size, type}` tuples where
  `type` is `:read` (master reads from slave) or `:write` (master writes to slave).
  `phys_start` must match the paired SM's start address.
  """

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

  @type profile :: %{
          outputs_size: non_neg_integer(),
          inputs_size: non_neg_integer(),
          sms: [sm_config()],
          fmmus: [fmmu_config()]
        }

  @doc "Return the SM/FMMU hardware profile for this slave type."
  @callback process_data_profile() :: profile()

  @doc "Encode a domain term into output bytes for the process image."
  @callback encode_outputs(term()) :: binary()

  @doc "Decode input bytes from the process image into a domain term."
  @callback decode_inputs(binary()) :: term()

  @doc "Called on entry to PreOp state. Optional."
  @callback on_preop(station :: non_neg_integer(), data :: map()) :: :ok

  @doc "Called on entry to SafeOp state. Optional."
  @callback on_safeop(station :: non_neg_integer(), data :: map()) :: :ok

  @doc "Called on entry to Op state. Optional."
  @callback on_op(station :: non_neg_integer(), data :: map()) :: :ok

  @optional_callbacks [on_preop: 2, on_safeop: 2, on_op: 2]
end
