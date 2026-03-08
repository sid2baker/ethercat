defmodule EtherCAT.DomainTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain
  alias EtherCAT.Domain.Layout

  defmodule FakeBus do
    use GenServer

    def start_link(responses) do
      GenServer.start_link(__MODULE__, responses)
    end

    @impl true
    def init(responses) do
      {:ok, responses}
    end

    @impl true
    def handle_call({:transact, _tx, _deadline_us, _enqueued_at_us}, _from, [reply | rest]) do
      {:reply, reply, rest}
    end
  end

  defmodule Relay do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      test_pid = Keyword.fetch!(opts, :test_pid)

      GenServer.start_link(__MODULE__, test_pid,
        name: {:via, Registry, {EtherCAT.Registry, {:slave, name}}}
      )
    end

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_info(msg, test_pid) do
      send(test_pid, {:relay, self(), msg})
      {:noreply, test_pid}
    end
  end

  setup do
    domain_id = :"domain_test_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, _pid} =
      start_supervised(
        {Domain, [id: domain_id, bus: self(), cycle_time_us: 60_000, miss_threshold: 500]}
      )

    %{domain_id: domain_id}
  end

  test "expected WKC counts each slave once per direction for LRW", %{domain_id: domain_id} do
    assert {:ok, 0} = Domain.register_pdo(domain_id, {:sensor, {:sm, 0}}, 2, :input)
    assert {:ok, 2} = Domain.register_pdo(domain_id, {:valve, {:sm, 0}}, 1, :output)
    assert {:ok, 3} = Domain.register_pdo(domain_id, {:valve, {:sm, 1}}, 1, :output)
    assert {:ok, 4} = Domain.register_pdo(domain_id, {:thermo, {:sm, 3}}, 8, :input)

    assert :ok = Domain.start_cycling(domain_id)
    assert {:ok, %{expected_wkc: 4}} = Domain.stats(domain_id)
  end

  test "start_cycling fails when nothing is registered", %{domain_id: domain_id} do
    assert {:error, :nothing_registered} = Domain.start_cycling(domain_id)
  end

  test "stop_cycling is idempotent while open", %{domain_id: domain_id} do
    assert :ok = Domain.stop_cycling(domain_id)
  end

  test "info reports the domain logical base", _context do
    logical_domain_id = :"domain_test_#{System.unique_integer([:positive, :monotonic])}_logical"

    {:ok, _pid} =
      start_supervised(
        {Domain,
         [
           id: logical_domain_id,
           bus: self(),
           cycle_time_us: 60_000,
           miss_threshold: 500,
           logical_base: 32
         ]}
      )

    assert {:ok, %{logical_base: 32, state: :open}} = Domain.info(logical_domain_id)
  end

  test "update_cycle_time changes the reported domain period", %{domain_id: domain_id} do
    assert :ok = Domain.update_cycle_time(domain_id, 10_000)
    assert {:ok, %{cycle_time_us: 10_000}} = Domain.info(domain_id)
  end

  test "sample reports staged output freshness metadata", %{domain_id: domain_id} do
    assert {:ok, 0} = Domain.register_pdo(domain_id, {:valve, {:sm, 0}}, 1, :output)

    assert {:ok, %{value: <<0>>, updated_at_us: nil}} =
             Domain.sample(domain_id, {:valve, {:sm, 0}})

    assert :ok = Domain.write(domain_id, {:valve, {:sm, 0}}, <<1>>)

    assert {:ok, %{value: <<1>>, updated_at_us: updated_at_us}} =
             Domain.sample(domain_id, {:valve, {:sm, 0}})

    assert is_integer(updated_at_us)
  end

  test "start_cycling fails fast for oversized LRW images", %{domain_id: domain_id} do
    assert {:ok, 0} = Domain.register_pdo(domain_id, {:big, :pdo}, 2036, :output)

    assert {:error, {:image_too_large, 2036, 2035}} = Domain.start_cycling(domain_id)
  end

  test "WKC mismatch marks the cycle invalid but keeps the domain running until recovery" do
    bus =
      start_supervised!({
        FakeBus,
        [
          {:ok, [%{data: <<0>>, wkc: 0, circular: false, irq: 0}]},
          {:ok, [%{data: <<1>>, wkc: 1, circular: false, irq: 0}]}
        ]
      })

    table = :ets.new(:"domain_table_#{System.unique_integer([:positive])}", [:set, :public])
    key = {:sensor, {:sm, 0}}
    :ets.insert(table, {key, :unset, self()})

    {_, layout} = Layout.register(Layout.new(), key, 1, :input)
    {:ok, cycle_plan} = Layout.prepare(layout)

    data = %Domain{
      id: :main,
      bus: bus,
      period_us: 1_000,
      logical_base: 0,
      next_cycle_at: System.monotonic_time(:microsecond) + 1_000,
      layout: layout,
      cycle_plan: cycle_plan,
      cycle_health: :healthy,
      table: table
    }

    assert {:keep_state, invalid_data, _actions} =
             Domain.handle_event(:state_timeout, :tick, :cycling, data)

    assert invalid_data.cycle_health ==
             {:invalid, {:wkc_mismatch, %{expected: 1, actual: 0}}}

    assert invalid_data.miss_count == 0
    assert is_integer(invalid_data.last_invalid_cycle_at_us)
    assert invalid_data.last_invalid_reason == {:wkc_mismatch, %{expected: 1, actual: 0}}

    assert {:keep_state, recovered_data, _actions} =
             Domain.handle_event(:state_timeout, :tick, :cycling, invalid_data)

    assert recovered_data.cycle_health == :healthy
    assert recovered_data.miss_count == 0
    assert is_integer(recovered_data.last_valid_cycle_at_us)
    assert is_integer(recovered_data.last_cycle_completed_at_us)
  end

  test "input dispatch resolves the current slave pid from the registry on each change" do
    bus =
      start_supervised!({
        FakeBus,
        [
          {:ok, [%{data: <<0>>, wkc: 1, circular: false, irq: 0}]},
          {:ok, [%{data: <<1>>, wkc: 1, circular: false, irq: 0}]}
        ]
      })

    key = {:sensor, {:sm, 0}}
    table = :ets.new(:"domain_table_#{System.unique_integer([:positive])}", [:set, :public])
    :ets.insert(table, {key, :unset, nil})

    {_, layout} = Layout.register(Layout.new(), key, 1, :input)
    {:ok, cycle_plan} = Layout.prepare(layout)

    data = %Domain{
      id: :main,
      bus: bus,
      period_us: 1_000,
      logical_base: 0,
      next_cycle_at: System.monotonic_time(:microsecond) + 1_000,
      layout: layout,
      cycle_plan: cycle_plan,
      cycle_health: :healthy,
      table: table
    }

    {:ok, first_relay} = Relay.start_link(name: :sensor, test_pid: self())

    assert {:keep_state, next_data, _actions} =
             Domain.handle_event(:state_timeout, :tick, :cycling, data)

    assert_receive {:relay, ^first_relay, {:domain_input, :main, ^key, :unset, <<0>>}}

    first_ref = Process.monitor(first_relay)
    GenServer.stop(first_relay, :normal)
    assert_receive {:DOWN, ^first_ref, :process, ^first_relay, :normal}

    {:ok, second_relay} = Relay.start_link(name: :sensor, test_pid: self())

    assert {:keep_state, _final_data, _actions} =
             Domain.handle_event(:state_timeout, :tick, :cycling, next_data)

    assert_receive {:relay, ^second_relay, {:domain_input, :main, ^key, <<0>>, <<1>>}}
  end
end
