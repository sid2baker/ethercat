defmodule EtherCAT.Domain.HealthNotificationsTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain
  alias EtherCAT.Domain.Layout
  alias EtherCAT.TestSupport.FakeBus

  setup do
    {:ok, setup_master_trace()}
  end

  test "WKC mismatch notifies invalid once and recovered on the next valid cycle", %{
    master_pid: master_pid,
    owns_master_name?: owns_master_name?
  } do
    bus =
      start_bus!([
        {:ok, [%{data: <<0>>, wkc: 0, circular: false, irq: 0}]},
        {:ok, [%{data: <<1>>, wkc: 1, circular: false, irq: 0}]}
      ])

    key = {:sensor, {:sm, 0}}
    data = build_cycling_data(bus, key)

    assert {:keep_state, invalid_data, _actions} =
             Domain.handle_event(:state_timeout, :tick, :cycling, data)

    assert_master_message(
      master_pid,
      owns_master_name?,
      {:domain_cycle_invalid, :main, {:wkc_mismatch, %{expected: 1, actual: 0}}}
    )

    assert {:keep_state, _recovered_data, _actions} =
             Domain.handle_event(:state_timeout, :tick, :cycling, invalid_data)

    assert_master_message(master_pid, owns_master_name?, {:domain_cycle_recovered, :main})
  end

  test "transport misses increment consecutive miss count and stop the domain at threshold", %{
    master_pid: master_pid,
    owns_master_name?: owns_master_name?
  } do
    bus = start_bus!([{:error, :timeout}, {:error, :timeout}])

    key = {:sensor, {:sm, 0}}
    data = build_cycling_data(bus, key, miss_threshold: 2)

    assert {:keep_state, once_missed, _actions} =
             Domain.handle_event(:state_timeout, :tick, :cycling, data)

    assert once_missed.miss_count == 1
    assert once_missed.cycle_health == {:invalid, :timeout}

    assert_master_message(master_pid, owns_master_name?, {:domain_cycle_invalid, :main, :timeout})

    assert {:next_state, :stopped, stopped_data} =
             Domain.handle_event(:state_timeout, :tick, :cycling, once_missed)

    assert stopped_data.miss_count == 2

    assert_master_message(master_pid, owns_master_name?, {:domain_stopped, :main, :timeout})
  end

  test "confirmed bus down stops the domain immediately without waiting for miss threshold", %{
    master_pid: master_pid,
    owns_master_name?: owns_master_name?
  } do
    bus = start_bus!([{:error, :down}])

    key = {:sensor, {:sm, 0}}
    data = build_cycling_data(bus, key)

    assert {:next_state, :stopped, stopped_data} =
             Domain.handle_event(:state_timeout, :tick, :cycling, data)

    assert stopped_data.miss_count == 1
    assert stopped_data.cycle_health == {:invalid, :down}

    assert_master_message(master_pid, owns_master_name?, {:domain_cycle_invalid, :main, :down})
    assert_master_message(master_pid, owns_master_name?, {:domain_stopped, :main, :down})
  end

  defp setup_master_trace do
    case Process.whereis(EtherCAT.Master) do
      nil ->
        Process.register(self(), EtherCAT.Master)

        on_exit(fn ->
          if Process.whereis(EtherCAT.Master) == self() do
            Process.unregister(EtherCAT.Master)
          end
        end)

        %{master_pid: self(), owns_master_name?: true}

      master_pid ->
        1 = :erlang.trace(master_pid, true, [:receive])
        on_exit(fn -> :erlang.trace(master_pid, false, [:receive]) end)
        %{master_pid: master_pid, owns_master_name?: false}
    end
  end

  defp build_cycling_data(bus, key, opts \\ []) do
    table = :ets.new(:"domain_table_#{System.unique_integer([:positive])}", [:set, :public])
    :ets.insert(table, {key, :unset, self()})

    {_, layout} = Layout.register(Layout.new(), key, 1, :input)
    {:ok, cycle_plan} = Layout.prepare(layout)

    %Domain{
      id: :main,
      bus: bus,
      period_us: 1_000,
      logical_base: 0,
      next_cycle_at: System.monotonic_time(:microsecond) + 1_000,
      layout: layout,
      cycle_plan: cycle_plan,
      cycle_health: :healthy,
      miss_threshold: Keyword.get(opts, :miss_threshold, 500),
      table: table
    }
  end

  defp start_bus!(responses) do
    start_supervised!(
      {FakeBus, [responses: responses, default_reply: {:error, :unexpected_transaction}]}
    )
  end

  defp assert_master_message(_master_pid, true, message) do
    assert_receive ^message
  end

  defp assert_master_message(master_pid, false, message) do
    assert_receive {:trace, ^master_pid, :receive, ^message}
  end
end
