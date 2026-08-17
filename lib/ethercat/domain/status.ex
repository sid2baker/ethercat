defmodule EtherCAT.Domain.Status do
  @moduledoc """
  Current protocol lifecycle and cycle health for one process-data domain.

  Domain status is retained by each attached slave runtime and included in the
  atomic result of `EtherCAT.subscribe/2`.
  """

  alias EtherCAT.Domain
  alias EtherCAT.Domain.Freshness
  alias EtherCAT.Domain.Layout

  @type lifecycle :: :open | :cycling | :stopped
  @type cycle_health :: :not_ready | :healthy | :degraded

  @enforce_keys [:id, :lifecycle, :cycle_health, :observed_at]
  defstruct [:id, :lifecycle, :cycle_health, :reason, :observed_at]

  @type t :: %__MODULE__{
          id: atom(),
          lifecycle: lifecycle(),
          cycle_health: cycle_health(),
          reason: term() | nil,
          observed_at: integer()
        }

  @doc false
  @spec protocol_status(atom(), lifecycle(), cycle_health(), term() | nil, integer()) :: t()
  def protocol_status(id, lifecycle, cycle_health, reason, observed_at) do
    %__MODULE__{
      id: id,
      lifecycle: lifecycle,
      cycle_health: cycle_health,
      reason: reason,
      observed_at: observed_at
    }
  end

  @doc false
  @spec stats_snapshot(atom(), %Domain{}) :: map()
  def stats_snapshot(state, data) do
    %{
      state: state,
      cycle_count: data.cycle_count,
      miss_count: data.miss_count,
      total_miss_count: data.total_miss_count,
      invalid_streak_count: data.invalid_streak_count,
      recovery_threshold: data.recovery_threshold,
      degraded?: data.degraded?,
      cycle_health: data.cycle_health,
      image_size: Layout.image_size(data.layout),
      expected_wkc: Layout.expected_wkc(data.layout),
      freshness: freshness_snapshot(data),
      last_valid_cycle_at_us: data.last_valid_cycle_at_us,
      last_invalid_cycle_at_us: data.last_invalid_cycle_at_us,
      last_invalid_reason: data.last_invalid_reason
    }
  end

  @doc false
  @spec info_snapshot(atom(), %Domain{}) :: map()
  def info_snapshot(state, data) do
    %{
      id: data.id,
      cycle_time_us: data.period_us,
      state: state,
      cycle_count: data.cycle_count,
      miss_count: data.miss_count,
      total_miss_count: data.total_miss_count,
      invalid_streak_count: data.invalid_streak_count,
      recovery_threshold: data.recovery_threshold,
      degraded?: data.degraded?,
      cycle_health: data.cycle_health,
      logical_base: data.logical_base,
      image_size: Layout.image_size(data.layout),
      expected_wkc: Layout.expected_wkc(data.layout),
      freshness: freshness_snapshot(data),
      last_cycle_started_at_us: data.last_cycle_started_at_us,
      last_cycle_completed_at_us: data.last_cycle_completed_at_us,
      last_valid_cycle_at_us: data.last_valid_cycle_at_us,
      last_invalid_cycle_at_us: data.last_invalid_cycle_at_us,
      last_invalid_reason: data.last_invalid_reason
    }
  end

  defp freshness_snapshot(data) do
    stale_after_us =
      if is_integer(data.stale_after_us) and data.stale_after_us > 0 do
        data.stale_after_us
      else
        Freshness.default_stale_after_us(data.period_us)
      end

    Freshness.snapshot(data.last_valid_cycle_at_us, stale_after_us)
  end
end
