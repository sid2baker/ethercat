defmodule EtherCAT.Slave.Config do
  @moduledoc """
  Declarative configuration struct for a Slave.

  Fields:
    - `:name` (required) — atom identifying this slave
    - `:driver` — module implementing `EtherCAT.Driver`,
      defaults to the built-in default driver
    - `:config` — driver-specific configuration map, default `%{}`
    - `:aliases` — optional `%{native_signal => effective_endpoint_name}` map
      that renames driver-native endpoints for this configured slave without
      changing the driver module itself
    - `:process_data` — one of:
      - `:none` — do not auto-register process data
      - `{:all, domain_id}` — register all signal names from the driver's
        `signal_model/2` against one domain
      - `[{signal_name, domain_id}]` — explicit signal-to-domain assignments
    - `:target_state` — desired startup target for this slave:
      - `:op` — master will advance it to cyclic operation
      - `:preop` — master will leave it in PREOP for manual configuration
    - `:sync` — optional `%EtherCAT.Slave.Sync.Config{}` describing slave-local
      SYNC0/SYNC1 and latch intent
    - `:health_poll_ms` — interval in milliseconds to poll AL Status after reaching `:op`.
      When set, the slave periodically reads register `0x0130` and emits a
      `[:ethercat, :slave, :health, :fault]` telemetry event if the slave has faulted
      or dropped out of Op. Defaults to `250`; set it to `nil` to disable polling.
  """

  @default_health_poll_ms 250

  @type process_data_request :: :none | {:all, atom()} | [{atom(), atom()}]
  @type target_state :: :preop | :op
  @type aliases :: %{optional(atom()) => atom()}
  @type t :: %__MODULE__{
          name: atom(),
          driver: module(),
          config: map(),
          aliases: aliases(),
          process_data: process_data_request(),
          target_state: target_state(),
          sync: EtherCAT.Slave.Sync.Config.t() | nil,
          health_poll_ms: pos_integer() | nil
        }

  @spec default_health_poll_ms() :: pos_integer()
  def default_health_poll_ms, do: @default_health_poll_ms

  @enforce_keys [:name]
  defstruct name: nil,
            driver: EtherCAT.Driver.Default,
            config: %{},
            aliases: %{},
            process_data: :none,
            target_state: :op,
            sync: nil,
            health_poll_ms: @default_health_poll_ms
end
