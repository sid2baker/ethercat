defmodule EtherCAT.MasterRecoveryBusTest do
  use ExUnit.Case, async: false

  alias EtherCAT.DC.Config, as: DCConfig
  alias EtherCAT.Domain
  alias EtherCAT.Domain, as: DomainAPI
  alias EtherCAT.TestSupport.FakeBus

  defmodule ReconnectStubSlave do
    @behaviour :gen_statem

    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.fetch!(opts, :name)},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      reg_name = {:via, Registry, {EtherCAT.Registry, {:slave, name}}}

      :gen_statem.start_link(
        reg_name,
        __MODULE__,
        %{
          name: name,
          test_pid: Keyword.fetch!(opts, :test_pid),
          authorize_reply: Keyword.get(opts, :authorize_reply, :ok),
          state: Keyword.get(opts, :state, :down)
        },
        []
      )
    end

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(%{state: state} = data), do: {:ok, state, data}

    @impl true
    def handle_event({:call, from}, :authorize_reconnect, :down, data) do
      send(data.test_pid, {:authorize_reconnect, data.name})
      {:keep_state, data, [{:reply, from, data.authorize_reply}]}
    end

    def handle_event({:call, from}, :authorize_reconnect, _state, data) do
      {:keep_state, data, [{:reply, from, {:error, :not_down}}]}
    end

    def handle_event({:call, from}, _event, _state, data) do
      {:keep_state, data, [{:reply, from, {:error, :unsupported}}]}
    end

    def handle_event(_type, _event, _state, _data), do: :keep_state_and_data
  end

  test "recovering retry restarts stopped domains even if bus info still carries a transport fault" do
    domain_id = :"master_domain_retry_#{System.unique_integer([:positive, :monotonic])}"

    bus =
      start_supervised!(
        {FakeBus,
         [
           name: EtherCAT.Bus,
           responses: List.duplicate({:ok, [%{data: <<0>>, wkc: 1, circular: false, irq: 0}]}, 8),
           info: %{topology: :single, fault: %{kind: :transport_fault}}
         ]}
      )

    {:ok, _pid} =
      start_supervised(
        {Domain, [id: domain_id, bus: bus, cycle_time_us: 1_000, miss_threshold: 500]}
      )

    assert {:ok, 0} = DomainAPI.register_pdo(domain_id, {:sensor, {:sm, 0}}, 1, :input)
    assert :ok = DomainAPI.start_cycling(domain_id)
    assert :ok = DomainAPI.stop_cycling(domain_id)
    assert {:ok, %{state: :stopped}} = DomainAPI.info(domain_id)

    data = %EtherCAT.Master{
      runtime_faults: %{{:domain, domain_id} => {:stopped, :down}}
    }

    assert {:keep_state, %EtherCAT.Master{} = recovering_data, _actions} =
             EtherCAT.Master.FSM.handle_event({:timeout, :retry}, nil, :recovering, data)

    assert recovering_data.runtime_faults == %{{:domain, domain_id} => {:stopped, :down}}
    assert {:ok, %{state: :cycling}} = DomainAPI.info(domain_id)
  end

  test "recovering retry keeps the DC runtime fault until the restarted worker proves success" do
    bus =
      start_supervised!(
        {FakeBus,
         [
           name: EtherCAT.Bus,
           responses: List.duplicate({:ok, [%{wkc: 1}]}, 8),
           info: %{state: :idle}
         ]}
      )

    data = %EtherCAT.Master{
      dc_config: %DCConfig{cycle_ns: 1_000_000},
      dc_ref_station: 0x1000,
      desired_runtime_target: :op,
      runtime_faults: %{{:dc, :runtime} => {:failed, :timeout}}
    }

    on_exit(fn ->
      case Process.whereis(EtherCAT.DC) do
        pid when is_pid(pid) ->
          DynamicSupervisor.terminate_child(EtherCAT.SessionSupervisor, pid)

        nil ->
          :ok
      end

      if Process.alive?(bus) do
        Process.exit(bus, :shutdown)
      end
    end)

    assert {:keep_state, %EtherCAT.Master{} = recovering_data, _actions} =
             EtherCAT.Master.FSM.handle_event({:timeout, :retry}, nil, :recovering, data)

    assert recovering_data.runtime_faults == %{{:dc, :runtime} => {:failed, :timeout}}
    assert is_pid(Process.whereis(EtherCAT.DC))
  end

  test "recovering retry reauthorizes a down slave once reconnect becomes possible" do
    slave_name = :"recovering_slave_retry_#{System.unique_integer([:positive, :monotonic])}"

    start_supervised!({ReconnectStubSlave, name: slave_name, test_pid: self()})

    data = %EtherCAT.Master{
      desired_runtime_target: :op,
      slave_faults: %{slave_name => {:down, :no_response}},
      runtime_faults: %{{:slave, slave_name} => {:down, :no_response}}
    }

    assert {:keep_state, %EtherCAT.Master{} = recovering_data, _actions} =
             EtherCAT.Master.FSM.handle_event({:timeout, :retry}, nil, :recovering, data)

    assert_receive {:authorize_reconnect, ^slave_name}

    assert recovering_data.slave_faults == %{slave_name => {:reconnecting, :authorized}}

    assert recovering_data.runtime_faults ==
             %{{:slave, slave_name} => {:reconnecting, :authorized}}
  end

  test "steady-state slave fault retry reauthorizes a down noncritical slave" do
    slave_name = :"slave_fault_retry_#{System.unique_integer([:positive, :monotonic])}"

    start_supervised!({ReconnectStubSlave, name: slave_name, test_pid: self()})

    data = %EtherCAT.Master{
      desired_runtime_target: :op,
      slave_faults: %{slave_name => {:down, :no_response}}
    }

    assert EtherCAT.Master.Recovery.retryable_slave_faults?(data)

    assert {:keep_state, %EtherCAT.Master{} = retried_data, _actions} =
             EtherCAT.Master.FSM.handle_event(
               {:timeout, :slave_fault_retry},
               nil,
               :operational,
               data
             )

    assert_receive {:authorize_reconnect, ^slave_name}
    assert retried_data.slave_faults == %{slave_name => {:reconnecting, :authorized}}
  end

  test "recovering retry leaves an in-flight reconnect alone when the slave is already not down" do
    slave_name = :"recovering_slave_booting_#{System.unique_integer([:positive, :monotonic])}"

    start_supervised!({ReconnectStubSlave, name: slave_name, test_pid: self(), state: :preop})

    data = %EtherCAT.Master{
      desired_runtime_target: :op,
      slave_faults: %{slave_name => {:reconnecting, :authorized}},
      runtime_faults: %{{:slave, slave_name} => {:down, :no_response}}
    }

    assert {:keep_state, %EtherCAT.Master{} = recovering_data, _actions} =
             EtherCAT.Master.FSM.handle_event({:timeout, :retry}, nil, :recovering, data)

    refute_receive {:authorize_reconnect, ^slave_name}
    assert recovering_data.slave_faults == %{slave_name => {:reconnecting, :authorized}}
    assert recovering_data.runtime_faults == %{{:slave, slave_name} => {:down, :no_response}}
  end

  test "recovering retry falls back to rediscovery when topology is back but a slave still cannot reconnect" do
    bus =
      start_supervised!(
        {FakeBus,
         [
           name: EtherCAT.Bus,
           responses: [{:ok, [%{data: <<0>>, wkc: 3, circular: false, irq: 0}]}],
           default_reply: {:error, :unexpected_transaction}
         ]}
      )

    data = %EtherCAT.Master{
      bus_ref: Process.monitor(bus),
      desired_runtime_target: :op,
      slave_count: 3,
      slaves: [coupler: 0x1000, inputs: 0x1001, outputs: 0x1002],
      slave_faults: %{outputs: {:reconnect_failed, :not_reconnected}},
      runtime_faults: %{
        {:domain, :main} => {:cycle_invalid, :timeout},
        {:slave, :outputs} => {:reconnect_failed, :not_reconnected}
      }
    }

    assert {:next_state, :discovering, %EtherCAT.Master{} = rediscovering} =
             EtherCAT.Master.FSM.handle_event({:timeout, :retry}, nil, :recovering, data)

    assert rediscovering.bus_ref == data.bus_ref
    assert rediscovering.slaves == []
    assert rediscovering.pending_preop == MapSet.new()
    assert rediscovering.runtime_faults == %{}
    assert rediscovering.slave_faults == %{}
    assert Process.alive?(bus)
    assert [_scan_tx] = FakeBus.calls(EtherCAT.Bus)
  end
end
