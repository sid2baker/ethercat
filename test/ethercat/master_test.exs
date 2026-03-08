defmodule EtherCAT.MasterTest do
  use ExUnit.Case, async: true

  alias EtherCAT.DC.Config, as: DCConfig
  alias EtherCAT.DC.Status, as: DCStatus
  alias EtherCAT.Domain

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

    def handle_call({:transact, _tx, _deadline_us, _enqueued_at_us}, _from, []) do
      {:reply, {:ok, [%{data: <<0>>, wkc: 1, circular: false, irq: 0}]}, []}
    end
  end

  test "phase reports preop_ready and operational distinctly" do
    from = {self(), make_ref()}

    assert {:keep_state_and_data, [{:reply, ^from, :preop_ready}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :phase,
               :running,
               %EtherCAT.Master{activation_phase: :preop_ready}
             )

    assert {:keep_state_and_data, [{:reply, ^from, :operational}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :phase,
               :running,
               %EtherCAT.Master{activation_phase: :operational}
             )

    assert {:keep_state_and_data, [{:reply, ^from, :degraded}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :phase,
               :degraded,
               %EtherCAT.Master{}
             )
  end

  test "await_operational waits through preop_ready and returns immediately once operational" do
    from = {self(), make_ref()}

    assert {:keep_state, %EtherCAT.Master{await_operational_callers: [^from]}} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :await_operational,
               :running,
               %EtherCAT.Master{activation_phase: :preop_ready, await_operational_callers: []}
             )

    assert {:keep_state_and_data, [{:reply, ^from, :ok}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :await_operational,
               :running,
               %EtherCAT.Master{activation_phase: :operational}
             )
  end

  test "await_operational reports activation failures in degraded mode" do
    from = {self(), make_ref()}
    failures = %{sensor: {:op, :no_response}}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, {:activation_failed, ^failures}}}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :await_operational,
               :degraded,
               %EtherCAT.Master{activation_failures: failures}
             )
  end

  test "await_operational reports runtime degradation details in degraded mode" do
    from = {self(), make_ref()}
    faults = %{{:domain, :main} => {:cycle_invalid, {:wkc_mismatch, %{expected: 2, actual: 1}}}}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, {:runtime_degraded, ^faults}}}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :await_operational,
               :degraded,
               %EtherCAT.Master{runtime_faults: faults}
             )
  end

  test "domain cycle invalid enters degraded and recovery returns to running" do
    reason = {:wkc_mismatch, %{expected: 2, actual: 1}}

    assert {:next_state, :degraded, %EtherCAT.Master{} = degraded_data} =
             EtherCAT.Master.handle_event(
               :info,
               {:domain_cycle_invalid, :main, reason},
               :running,
               %EtherCAT.Master{activation_phase: :operational}
             )

    assert degraded_data.runtime_faults == %{{:domain, :main} => {:cycle_invalid, reason}}

    assert {:next_state, :running, %EtherCAT.Master{runtime_faults: %{}}} =
             EtherCAT.Master.handle_event(
               :info,
               {:domain_cycle_recovered, :main},
               :degraded,
               degraded_data
             )
  end

  test "degraded retry restarts stopped domains once activation failures are clear" do
    domain_id = :"master_domain_retry_#{System.unique_integer([:positive, :monotonic])}"

    bus =
      start_supervised!(
        {FakeBus, List.duplicate({:ok, [%{data: <<0>>, wkc: 1, circular: false, irq: 0}]}, 8)}
      )

    {:ok, _pid} =
      start_supervised(
        {Domain, [id: domain_id, bus: bus, cycle_time_us: 1_000, miss_threshold: 500]}
      )

    assert {:ok, 0} = Domain.register_pdo(domain_id, {:sensor, {:sm, 0}}, 1, :input)
    assert :ok = Domain.start_cycling(domain_id)
    assert :ok = Domain.stop_cycling(domain_id)
    assert {:ok, %{state: :stopped}} = Domain.info(domain_id)

    data = %EtherCAT.Master{
      activation_phase: :operational,
      runtime_faults: %{{:domain, domain_id} => {:stopped, :down}}
    }

    assert {:keep_state, %EtherCAT.Master{} = degraded_data, _actions} =
             EtherCAT.Master.handle_event({:timeout, :degraded_retry}, nil, :degraded, data)

    assert degraded_data.runtime_faults == %{{:domain, domain_id} => {:stopped, :down}}
    assert {:ok, %{state: :cycling}} = Domain.info(domain_id)
  end

  test "last_failure is queryable in idle and active states" do
    from = {self(), make_ref()}
    failure = %{kind: :configuration_failed, reason: :no_response, at_ms: 123}

    assert {:keep_state_and_data, [{:reply, ^from, ^failure}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :last_failure,
               :idle,
               %EtherCAT.Master{last_failure: failure}
             )

    assert {:keep_state_and_data, [{:reply, ^from, ^failure}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :last_failure,
               :scanning,
               %EtherCAT.Master{last_failure: failure}
             )
  end

  test "dc_status reports disabled when no DC config is present" do
    from = {self(), make_ref()}

    assert {:keep_state_and_data, [{:reply, ^from, %DCStatus{lock_state: :disabled}}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :dc_status,
               :idle,
               %EtherCAT.Master{}
             )
  end

  test "dc_status reports configured inactive DC before runtime starts" do
    from = {self(), make_ref()}

    data = %EtherCAT.Master{
      dc_config: %DCConfig{cycle_ns: 1_000_000},
      dc_ref_station: 0x1001,
      slaves: [{:sensor, 0x1001}]
    }

    assert {:keep_state_and_data,
            [
              {:reply, ^from,
               %DCStatus{
                 configured?: true,
                 active?: false,
                 cycle_ns: 1_000_000,
                 reference_station: 0x1001,
                 reference_clock: :sensor,
                 lock_state: :inactive
               }}
            ]} =
             EtherCAT.Master.handle_event({:call, from}, :dc_status, :running, data)
  end

  test "reference_clock and dc_runtime use dc runtime semantics" do
    from = {self(), make_ref()}

    data = %EtherCAT.Master{
      dc_config: %DCConfig{cycle_ns: 1_000_000},
      dc_ref_station: 0x1002,
      slaves: [{:thermo, 0x1002}]
    }

    assert {:keep_state_and_data, [{:reply, ^from, {:ok, %{name: :thermo, station: 0x1002}}}]} =
             EtherCAT.Master.handle_event({:call, from}, :reference_clock, :running, data)

    assert {:keep_state_and_data, [{:reply, ^from, {:error, :dc_inactive}}]} =
             EtherCAT.Master.handle_event({:call, from}, :dc_runtime, :running, data)
  end

  test "slaves query resolves registry-backed server refs and current pids" do
    from = {self(), make_ref()}

    relay =
      start_supervised!(%{
        id: make_ref(),
        start:
          {Agent, :start_link,
           [fn -> :ok end, [name: {:via, Registry, {EtherCAT.Registry, {:slave, :sensor}}}]]}
      })

    assert {:keep_state_and_data,
            [
              {:reply, ^from,
               [
                 %{
                   name: :sensor,
                   station: 0x1001,
                   server: {:via, Registry, {EtherCAT.Registry, {:slave, :sensor}}},
                   pid: ^relay
                 }
               ]}
            ]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :slaves,
               :running,
               %EtherCAT.Master{slaves: [{:sensor, 0x1001}]}
             )
  end

  test "dc_runtime reports disabled and active states distinctly" do
    from = {self(), make_ref()}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, :dc_disabled}}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :dc_runtime,
               :running,
               %EtherCAT.Master{}
             )

    start_supervised!(%{
      id: make_ref(),
      start: {Agent, :start_link, [fn -> :ok end, [name: EtherCAT.DC]]}
    })

    assert {:keep_state_and_data, [{:reply, ^from, {:ok, EtherCAT.DC}}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :dc_runtime,
               :running,
               %EtherCAT.Master{dc_config: %DCConfig{}}
             )
  end
end
