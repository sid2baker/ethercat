defmodule EtherCAT.Slave.Config do
  @moduledoc """
  Declarative configuration struct for a Slave.

  Fields:
    - `:name` (required) — atom identifying this slave
    - `:driver` — module implementing `EtherCAT.Slave.Driver`,
      defaults to `EtherCAT.Slave.Driver.Default`
    - `:config` — driver-specific configuration map, default `%{}`
    - `:process_data` — one of:
      - `:none` — do not auto-register process data
      - `{:all, domain_id}` — register all signal names from the driver's
        `process_data_model/1` against one domain
      - `[{signal_name, domain_id}]` — explicit signal-to-domain assignments
    - `:target_state` — desired startup target for this slave:
      - `:op` — master will advance it to cyclic operation
      - `:preop` — master will leave it in PREOP for manual configuration
    - `:sync` — optional `%EtherCAT.Slave.Sync.Config{}` describing slave-local
      SYNC0/SYNC1 and latch intent
  """

  @type process_data_request :: :none | {:all, atom()} | [{atom(), atom()}]
  @type target_state :: :preop | :op
  @type t :: %__MODULE__{
          name: atom(),
          driver: module(),
          config: map(),
          process_data: process_data_request(),
          target_state: target_state(),
          sync: EtherCAT.Slave.Sync.Config.t() | nil
        }

  @enforce_keys [:name]
  defstruct name: nil,
            driver: EtherCAT.Slave.Driver.Default,
            config: %{},
            process_data: :none,
            target_state: :op,
            sync: nil
end
