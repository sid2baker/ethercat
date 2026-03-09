defmodule EtherCAT.Domain.Status do
  @moduledoc false

  alias EtherCAT.Domain
  alias EtherCAT.Domain.Layout

  @spec stats_snapshot(atom(), %Domain{}) :: map()
  def stats_snapshot(state, data) do
    %{
      state: state,
      cycle_count: data.cycle_count,
      miss_count: data.miss_count,
      total_miss_count: data.total_miss_count,
      cycle_health: data.cycle_health,
      image_size: Layout.image_size(data.layout),
      expected_wkc: Layout.expected_wkc(data.layout),
      last_valid_cycle_at_us: data.last_valid_cycle_at_us,
      last_invalid_cycle_at_us: data.last_invalid_cycle_at_us,
      last_invalid_reason: data.last_invalid_reason
    }
  end

  @spec info_snapshot(atom(), %Domain{}) :: map()
  def info_snapshot(state, data) do
    %{
      id: data.id,
      cycle_time_us: data.period_us,
      state: state,
      cycle_count: data.cycle_count,
      miss_count: data.miss_count,
      total_miss_count: data.total_miss_count,
      cycle_health: data.cycle_health,
      logical_base: data.logical_base,
      image_size: Layout.image_size(data.layout),
      expected_wkc: Layout.expected_wkc(data.layout),
      last_cycle_started_at_us: data.last_cycle_started_at_us,
      last_cycle_completed_at_us: data.last_cycle_completed_at_us,
      last_valid_cycle_at_us: data.last_valid_cycle_at_us,
      last_invalid_cycle_at_us: data.last_invalid_cycle_at_us,
      last_invalid_reason: data.last_invalid_reason
    }
  end
end
