defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Behaviour for slave-specific drivers.

  A driver declares the SM/FMMU hardware profile for a slave type and handles
  encoding output domain terms to raw binary and decoding raw binary inputs back
  to domain terms. The library handles all register I/O and the process image
  exchange; the driver owns data interpretation.

  ## Profile format

  `process_data_profile/0` must return a map with a `:pdos` key — a list of PDO
  groups, each assigned to a domain:

      %{pdos: [
        %{
          domain:       :default,      # which domain this group belongs to
          outputs_size: 2,             # bytes written by master each cycle
          inputs_size:  0,             # bytes read by master each cycle
          sms:          [{2, 0x0F00, 2, 0x44}],
          fmmus:        [{0, 0x0F00, 2, :write}]
        }
      ]}

  The `:domain` key is an atom matching a running `EtherCAT.Domain` id, or `:default`
  which resolves to whichever domain called `EtherCAT.Domain.set_default/1`. Slaves
  with PDOs on `:default` and no default domain configured are silently skipped.

  A slave can split PDOs across multiple domains (e.g. fast torque loop + slow
  diagnostics):

      %{pdos: [
        %{domain: :fast, outputs_size: 4, inputs_size: 4, sms: [...], fmmus: [...]},
        %{domain: :slow, outputs_size: 2, inputs_size: 2, sms: [...], fmmus: [...]}
      ]}

  ## Backward compatibility

  The old flat profile shape is accepted and automatically normalised to the new
  format by `EtherCAT.Slave`:

      # Old shape (still works — treated as domain: :default)
      %{outputs_size: 2, inputs_size: 0, sms: [...], fmmus: [...]}

  ## Minimal example — 16-channel digital output (EL2809)

      defmodule MyApp.EL2809 do
        @behaviour EtherCAT.Slave.Driver

        @impl true
        def process_data_profile do
          %{pdos: [%{
            domain:       :default,
            outputs_size: 2,
            inputs_size:  0,
            sms:          [{2, 0x0F00, 2, 0x44}],
            fmmus:        [{0, 0x0F00, 2, :write}]
          }]}
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
          %{pdos: [%{
            domain:       :default,
            outputs_size: 0,
            inputs_size:  2,
            sms:          [{3, 0x1000, 2, 0x20}],
            fmmus:        [{1, 0x1000, 2, :read}]
          }]}
        end

        @impl true
        def encode_outputs(_), do: <<>>

        @impl true
        def decode_inputs(<<channels::16-little>>), do: channels
        def decode_inputs(_), do: 0
      end

  ## SM ctrl byte reference

  `sms` entries are `{sm_index, phys_start, length, ctrl}` tuples.

    - bits [1:0] — mode: `0b00` = buffered (3-buffer), `0b10` = mailbox
    - bits [3:2] — direction: `0b00` = ECAT reads (input), `0b01` = ECAT writes (output)
    - bit [5]    — AL event interrupt enable
    - bit [6]    — watchdog trigger enable (set for output SMs)

  Common values: `0x20` inputs, `0x24` outputs, `0x44` outputs + WDT trigger.

  `fmmus` entries are `{fmmu_index, phys_start, size, :read | :write}` tuples.
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

  @type pdo_group :: %{
          domain: atom(),
          outputs_size: non_neg_integer(),
          inputs_size: non_neg_integer(),
          sms: [sm_config()],
          fmmus: [fmmu_config()]
        }

  @type profile :: %{pdos: [pdo_group()]}

  @doc """
  Return the SM/FMMU hardware profile for this slave type.

  Must return `%{pdos: [pdo_group()]}`. The old flat map shape is also accepted
  and normalised automatically by `EtherCAT.Slave`.
  """
  @callback process_data_profile() :: profile() | map()

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
