defmodule EtherCAT.Domain.Freshness do
  @moduledoc false

  @status_key :"$domain_status"
  @default_cycles 3

  @type snapshot :: %{
          required(:state) => :not_ready | :fresh | :stale,
          required(:refreshed_at_us) => integer() | nil,
          required(:age_us) => non_neg_integer() | nil,
          required(:stale_after_us) => pos_integer()
        }

  @spec status_key() :: atom()
  def status_key, do: @status_key

  @spec default_stale_after_us(pos_integer()) :: pos_integer()
  def default_stale_after_us(period_us) when is_integer(period_us) and period_us > 0 do
    period_us * @default_cycles
  end

  @spec snapshot(integer() | nil, pos_integer(), integer()) :: snapshot()
  def snapshot(refreshed_at_us, stale_after_us, now_us \\ System.monotonic_time(:microsecond))

  def snapshot(nil, stale_after_us, _now_us)
      when is_integer(stale_after_us) and stale_after_us > 0 do
    %{
      state: :not_ready,
      refreshed_at_us: nil,
      age_us: nil,
      stale_after_us: stale_after_us
    }
  end

  def snapshot(refreshed_at_us, stale_after_us, now_us)
      when is_integer(refreshed_at_us) and is_integer(stale_after_us) and stale_after_us > 0 and
             is_integer(now_us) do
    age_us = max(now_us - refreshed_at_us, 0)

    %{
      state: if(age_us > stale_after_us, do: :stale, else: :fresh),
      refreshed_at_us: refreshed_at_us,
      age_us: age_us,
      stale_after_us: stale_after_us
    }
  end

  @spec stale_details(snapshot()) :: map() | nil
  def stale_details(%{state: :stale} = snapshot) do
    Map.take(snapshot, [:refreshed_at_us, :age_us, :stale_after_us])
  end

  def stale_details(_snapshot), do: nil
end
