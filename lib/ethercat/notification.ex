defmodule EtherCAT.Notification do
  @moduledoc """
  Protocol-level runtime notification for one configured slave.

  Notifications report EtherCAT runtime facts only. They do not infer machine
  availability, command completion, or semantic events.

  A subscriber receives `:slave_state_changed` when the slave runtime enters a
  different EtherCAT state and `:domain_status_changed` when the lifecycle or
  cycle health of an attached process-data domain changes.

  `observed_at` is a host monotonic timestamp in microseconds, not wall-clock
  time or EtherCAT distributed-clock time. Compare it only within the same VM.
  """

  alias EtherCAT.Domain.Status, as: DomainStatus
  alias EtherCAT.Slave.Status, as: SlaveStatus

  @type kind :: :slave_state_changed | :domain_status_changed

  @type details ::
          %{
            required(:previous_state) => SlaveStatus.state(),
            required(:current) => SlaveStatus.t()
          }
          | %{required(:current) => DomainStatus.t()}

  @enforce_keys [:slave, :kind, :observed_at, :details]
  defstruct [:slave, :kind, :observed_at, :details]

  @type t :: %__MODULE__{
          slave: atom(),
          kind: kind(),
          observed_at: integer(),
          details: details()
        }

  @doc false
  @spec slave_state_changed(atom(), SlaveStatus.state(), SlaveStatus.t(), integer()) :: t()
  def slave_state_changed(slave, previous_state, %SlaveStatus{} = current, observed_at) do
    %__MODULE__{
      slave: slave,
      kind: :slave_state_changed,
      observed_at: observed_at,
      details: %{previous_state: previous_state, current: current}
    }
  end

  @doc false
  @spec domain_status_changed(atom(), DomainStatus.t()) :: t()
  def domain_status_changed(slave, %DomainStatus{} = current) do
    %__MODULE__{
      slave: slave,
      kind: :domain_status_changed,
      observed_at: current.observed_at,
      details: %{current: current}
    }
  end
end
