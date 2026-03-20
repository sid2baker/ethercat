defmodule EtherCAT.Domain.HealthNotificationsTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain
  alias EtherCAT.Domain.Layout
  alias EtherCAT.TestSupport.FakeBus

  setup do
    {:ok, setup_master_trace()}
  end

  test "WKC mismatch notifies degraded only after the recovery threshold and recovered on the next valid cycle",
       %{
         master_pid: master_pid,
         owns_master_name?: owns_master_name?
       } do
    bus =
      start_bus!([
        {:ok, [%{data: <<0>>, wkc: 0, circular: false, irq: 0}]},
        {:ok, [%{data: <<0>>, wkc: 0, circular: false, irq: 0}]},
        {:ok, [%{data: <<1>>, wkc: 1, circular: false, irq: 0}]}
      ])

    key = {:sensor, {:sm, 0}}
    data = build_cycling_data(bus, key, recovery_threshold: 2)

    assert {:keep_state, first_invalid, _actions} =
             Domain.FSM.handle_event(:state_timeout, :tick, :cycling, data)

    assert_no_master_message(master_pid, owns_master_name?)

    assert {:keep_state, degraded_data, _actions} =
             Domain.FSM.handle_event(:state_timeout, :tick, :cycling, first_invalid)

    assert_master_message(
      master_pid,
      owns_master_name?,
      {:domain_cycle_degraded, :main, {:wkc_mismatch, %{expected: 1, actual: 0}}, 2}
    )

    assert {:keep_state, _recovered_data, _actions} =
             Domain.FSM.handle_event(:state_timeout, :tick, :cycling, degraded_data)

    assert_master_message(master_pid, owns_master_name?, {:domain_cycle_recovered, :main})
  end

  test "transport misses stop the domain at the miss threshold without escalating the master early",
       %{
         master_pid: master_pid,
         owns_master_name?: owns_master_name?
       } do
    bus = start_bus!([{:error, :timeout}, {:error, :timeout}])

    key = {:sensor, {:sm, 0}}
    data = build_cycling_data(bus, key, miss_threshold: 2)

    assert {:keep_state, once_missed, _actions} =
             Domain.FSM.handle_event(:state_timeout, :tick, :cycling, data)

    assert once_missed.miss_count == 1
    assert once_missed.cycle_health == {:invalid, :timeout}

    assert_no_master_message(master_pid, owns_master_name?)

    assert {:next_state, :stopped, stopped_data} =
             Domain.FSM.handle_event(:state_timeout, :tick, :cycling, once_missed)

    assert stopped_data.miss_count == 2

    assert_master_message(master_pid, owns_master_name?, {:domain_stopped, :main, :timeout})
  end

  test "confirmed bus down stops the domain immediately without sending a degraded-cycle warning",
       %{
         master_pid: master_pid,
         owns_master_name?: owns_master_name?
       } do
    bus = start_bus!([{:error, :down}])

    key = {:sensor, {:sm, 0}}
    data = build_cycling_data(bus, key)

    assert {:next_state, :stopped, stopped_data} =
             Domain.FSM.handle_event(:state_timeout, :tick, :cycling, data)

    assert stopped_data.miss_count == 1
    assert stopped_data.cycle_health == {:invalid, :down}

    refute_master_message(
      master_pid,
      owns_master_name?,
      {:domain_cycle_degraded, :main, :down, 1}
    )

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
      recovery_threshold: Keyword.get(opts, :recovery_threshold, 3),
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

  defp refute_master_message(_master_pid, true, message) do
    refute_receive ^message
  end

  defp refute_master_message(master_pid, false, message) do
    refute_receive {:trace, ^master_pid, :receive, ^message}
  end

  defp assert_no_master_message(_master_pid, true) do
    refute_receive {:domain_cycle_degraded, _, _, _}
    refute_receive {:domain_cycle_recovered, _}
    refute_receive {:domain_stopped, _, _}
  end

  defp assert_no_master_message(master_pid, false) do
    refute_receive {:trace, ^master_pid, :receive, {:domain_cycle_degraded, _, _, _}}
    refute_receive {:trace, ^master_pid, :receive, {:domain_cycle_recovered, _}}
    refute_receive {:trace, ^master_pid, :receive, {:domain_stopped, _, _}}
  end
end
