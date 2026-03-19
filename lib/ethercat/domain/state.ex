defmodule EtherCAT.Domain.State do
  @moduledoc false

  alias EtherCAT.Domain
  alias EtherCAT.Domain.Freshness
  alias EtherCAT.Domain.Image
  alias EtherCAT.Domain.Layout

  @spec new(keyword()) :: %Domain{}
  def new(opts) do
    id = Keyword.fetch!(opts, :id)

    table =
      :ets.new(id, [
        :set,
        :public,
        :named_table,
        {:write_concurrency, true},
        {:read_concurrency, true}
      ])

    stale_after_us = Freshness.default_stale_after_us(Keyword.fetch!(opts, :cycle_time_us))
    Image.put_domain_status(table, nil, stale_after_us)

    Registry.register(EtherCAT.Registry, {:domain, id}, id)

    %Domain{
      id: id,
      bus: Keyword.fetch!(opts, :bus),
      period_us: Keyword.fetch!(opts, :cycle_time_us),
      logical_base: Keyword.get(opts, :logical_base, 0),
      next_cycle_at: nil,
      last_cycle_started_at_us: nil,
      last_cycle_completed_at_us: nil,
      last_valid_cycle_at_us: nil,
      last_invalid_cycle_at_us: nil,
      last_invalid_reason: nil,
      stale_after_us: stale_after_us,
      layout: Layout.new(),
      cycle_plan: nil,
      cycle_health: :healthy,
      miss_count: 0,
      miss_threshold: Keyword.get(opts, :miss_threshold, 100),
      invalid_streak_count: 0,
      degraded?: false,
      recovery_threshold: Keyword.get(opts, :recovery_threshold, 3),
      cycle_count: 0,
      total_miss_count: 0,
      table: table
    }
  end
end
