defmodule EtherCAT.MasterRecoveryBusTest do
  use ExUnit.Case, async: false

  alias EtherCAT.DC.Config, as: DCConfig
  alias EtherCAT.Domain
  alias EtherCAT.Domain, as: DomainAPI
  alias EtherCAT.TestSupport.FakeBus

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

  test "recovering retry leaves a down slave fault in place while waiting for autonomous reconnect" do
    slave_name = :"recovering_slave_retry_#{System.unique_integer([:positive, :monotonic])}"

    data = %EtherCAT.Master{
      desired_runtime_target: :op,
      slave_faults: %{slave_name => {:down, :no_response}},
      runtime_faults: %{{:slave, slave_name} => {:down, :no_response}}
    }

    assert {:keep_state, %EtherCAT.Master{} = recovering_data, _actions} =
             EtherCAT.Master.FSM.handle_event({:timeout, :retry}, nil, :recovering, data)

    assert recovering_data.slave_faults == %{slave_name => {:down, :no_response}}
    assert recovering_data.runtime_faults == %{{:slave, slave_name} => {:down, :no_response}}
  end

  test "steady-state down slave faults are not retried by the master anymore" do
    slave_name = :"slave_fault_retry_#{System.unique_integer([:positive, :monotonic])}"

    data = %EtherCAT.Master{
      desired_runtime_target: :op,
      slave_faults: %{slave_name => {:down, :no_response}}
    }

    refute EtherCAT.Master.Recovery.retryable_slave_faults?(data)

    assert {:keep_state, %EtherCAT.Master{} = retried_data, _actions} =
             EtherCAT.Master.FSM.handle_event(
               {:timeout, :slave_fault_retry},
               nil,
               :operational,
               data
             )

    assert retried_data.slave_faults == %{slave_name => {:down, :no_response}}
  end

  test "recovering retry leaves reconnect_failed faults in place without rediscovery fallback" do
    data = %EtherCAT.Master{
      desired_runtime_target: :op,
      slave_faults: %{outputs: {:reconnect_failed, :not_reconnected}},
      runtime_faults: %{{:slave, :outputs} => {:reconnect_failed, :not_reconnected}}
    }

    assert {:keep_state, %EtherCAT.Master{} = recovering_data, _actions} =
             EtherCAT.Master.FSM.handle_event({:timeout, :retry}, nil, :recovering, data)

    assert recovering_data.slave_faults == %{outputs: {:reconnect_failed, :not_reconnected}}

    assert recovering_data.runtime_faults ==
             %{{:slave, :outputs} => {:reconnect_failed, :not_reconnected}}
  end

  test "recovering retry keeps other runtime faults while waiting for autonomous slave reconnect" do
    data = %EtherCAT.Master{
      desired_runtime_target: :op,
      slave_faults: %{outputs: {:down, :no_response}},
      runtime_faults: %{
        {:domain, :main} => {:cycle_degraded, %{reason: :timeout, consecutive: 3}},
        {:slave, :outputs} => {:down, :no_response}
      }
    }

    assert {:keep_state, %EtherCAT.Master{} = recovering_data, _actions} =
             EtherCAT.Master.FSM.handle_event({:timeout, :retry}, nil, :recovering, data)

    assert recovering_data.runtime_faults ==
             %{
               {:domain, :main} => {:cycle_degraded, %{reason: :timeout, consecutive: 3}},
               {:slave, :outputs} => {:down, :no_response}
             }

    assert recovering_data.slave_faults == %{outputs: {:down, :no_response}}
  end
end
