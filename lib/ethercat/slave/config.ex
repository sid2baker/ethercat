defmodule EtherCAT.Slave.Config do
  @moduledoc """
  Declarative configuration for one slave in physical bus order.

  Pass these entries in `EtherCAT.start/1`'s `:slaves` list. Names are application
  identifiers, not device matching rules; the runtime does not select a position
  by driver identity. Explicit entries default to `target_state: :op`, whereas
  discovery without a slave list creates PREOP-held configurations.

  Fields:
    - `:name` (required) — atom identifying this slave
    - `:driver` — module implementing `EtherCAT.Driver`,
      defaults to the built-in default driver
    - `:config` — driver-specific configuration map, default `%{}`
    - `:process_data` — one of:
      - `:none` (default) — do not auto-register process data
      - `{:all, domain_id}` — register all signal names from the driver's
        `signal_model/2` against one domain
      - `[{signal_name, domain_id}]` — explicit signal-to-domain assignments
    - `:target_state` — desired startup target for this slave:
      - `:op` (default) — master will attempt to advance it to OP
      - `:preop` — master will leave it in PREOP for manual configuration
    - `:sync` — optional `%EtherCAT.Slave.Sync.Config{}` describing slave-local
      SYNC0/SYNC1 and latch intent
    - `:health_poll_ms` — AL Status polling interval in milliseconds, default `250`;
      set `nil` to disable polling. Runtime polling detects disconnects and AL-state
      regressions in OP and runtime-held PREOP/SAFEOP. It is suppressed while the
      whole session is held in its initial PREOP provisioning phase, then restored
      on activation, including for slaves whose target remains PREOP.
  """

  @default_health_poll_ms 250

  @type process_data_request :: :none | {:all, atom()} | [{atom(), atom()}]
  @type target_state :: :preop | :op
  @type t :: %__MODULE__{
          name: atom(),
          driver: module(),
          config: map(),
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
            process_data: :none,
            target_state: :op,
            sync: nil,
            health_poll_ms: @default_health_poll_ms
end
