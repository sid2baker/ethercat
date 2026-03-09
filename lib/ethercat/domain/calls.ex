defmodule EtherCAT.Domain.Calls do
  @moduledoc false

  alias EtherCAT.Domain
  alias EtherCAT.Domain.Cycle
  alias EtherCAT.Domain.Image
  alias EtherCAT.Domain.Layout
  alias EtherCAT.Domain.Status

  @spec register_pdo(term(), Domain.pdo_key(), pos_integer(), :input | :output, %Domain{}) ::
          :gen_statem.event_handler_result(atom())
  def register_pdo(from, key, size, direction, data) do
    {offset, layout} = Layout.register(data.layout, key, size, direction)
    Image.insert_registration_entry(data.table, key, size, direction)

    new_data = %{data | layout: layout}

    {:keep_state, new_data, [{:reply, from, {:ok, data.logical_base + offset}}]}
  end

  @spec start_cycling(term(), atom(), %Domain{}) :: :gen_statem.event_handler_result(atom())
  def start_cycling(from, :cycling, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_cycling}}]}
  end

  def start_cycling(from, state, data) when state in [:open, :stopped] do
    Cycle.start_reply(from, data, reset_miss_count?(state))
  end

  @spec stop_cycling(term(), atom(), %Domain{}) :: :gen_statem.event_handler_result(atom())
  def stop_cycling(from, state, data) when state in [:open, :stopped] do
    _ = data
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def stop_cycling(from, :cycling, data) do
    {:next_state, :stopped, data, [{:reply, from, :ok}]}
  end

  @spec stats(term(), atom(), %Domain{}) :: :gen_statem.event_handler_result(atom())
  def stats(from, state, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, Status.stats_snapshot(state, data)}}]}
  end

  @spec info(term(), atom(), %Domain{}) :: :gen_statem.event_handler_result(atom())
  def info(from, state, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, Status.info_snapshot(state, data)}}]}
  end

  @spec update_cycle_time(term(), pos_integer(), %Domain{}) ::
          :gen_statem.event_handler_result(atom())
  def update_cycle_time(from, new_us, data) do
    {:keep_state, %{data | period_us: new_us}, [{:reply, from, :ok}]}
  end

  defp reset_miss_count?(:stopped), do: true
  defp reset_miss_count?(:open), do: false
end
