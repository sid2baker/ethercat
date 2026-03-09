defmodule EtherCAT.MasterTest do
  use ExUnit.Case, async: true

  alias EtherCAT.DC.Config, as: DCConfig
  alias EtherCAT.DC.Status, as: DCStatus
  alias EtherCAT.Domain
  alias EtherCAT.Master.Config.DomainPlan

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

  defmodule FakeDC do
    @behaviour :gen_statem

    def start_link(status) do
      :gen_statem.start_link({:local, EtherCAT.DC}, __MODULE__, status, [])
    end

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(status), do: {:ok, :running, status}

    @impl true
    def handle_event({:call, from}, :status, :running, status) do
      {:keep_state_and_data, [{:reply, from, status}]}
    end

    def handle_event(_type, _event, _state, data), do: {:keep_state, data}
  end

  defmodule FakeSlave do
    @behaviour :gen_statem

    def start_link(name, authorize_reply \\ :ok) do
      :gen_statem.start_link(
        {:via, Registry, {EtherCAT.Registry, {:slave, name}}},
        __MODULE__,
        authorize_reply,
        []
      )
    end

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(authorize_reply), do: {:ok, :down, authorize_reply}

    @impl true
    def handle_event({:call, from}, :authorize_reconnect, :down, authorize_reply) do
      {:keep_state_and_data, [{:reply, from, authorize_reply}]}
    end

    def handle_event({:call, from}, {:request, :op}, _state, _data) do
      {:keep_state_and_data, [{:reply, from, :ok}]}
    end

    def handle_event(_type, _event, _state, data), do: {:keep_state, data}
  end

  test "state reports preop_ready and operational distinctly" do
    from = {self(), make_ref()}

    assert {:keep_state_and_data, [{:reply, ^from, :preop_ready}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :state,
               :preop_ready,
               %EtherCAT.Master{}
             )

    assert {:keep_state_and_data, [{:reply, ^from, :operational}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :state,
               :operational,
               %EtherCAT.Master{}
             )

    assert {:keep_state_and_data, [{:reply, ^from, :activation_blocked}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :state,
               :activation_blocked,
               %EtherCAT.Master{}
             )

    assert {:keep_state_and_data, [{:reply, ^from, :recovering}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :state,
               :recovering,
               %EtherCAT.Master{}
             )
  end

  test "await_operational waits through preop_ready and returns immediately once operational" do
    from = {self(), make_ref()}

    assert {:keep_state, %EtherCAT.Master{await_operational_callers: [^from]}} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :await_operational,
               :preop_ready,
               %EtherCAT.Master{await_operational_callers: []}
             )

    assert {:keep_state_and_data, [{:reply, ^from, :ok}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :await_operational,
               :operational,
               %EtherCAT.Master{}
             )
  end

  test "await_operational reports activation failures in activation_blocked mode" do
    from = {self(), make_ref()}
    failures = %{sensor: {:op, :no_response}}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, {:activation_failed, ^failures}}}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :await_operational,
               :activation_blocked,
               %EtherCAT.Master{activation_failures: failures}
             )
  end

  test "await_operational reports runtime degradation details in recovering mode" do
    from = {self(), make_ref()}
    faults = %{{:domain, :main} => {:cycle_invalid, {:wkc_mismatch, %{expected: 2, actual: 1}}}}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, {:runtime_degraded, ^faults}}}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :await_operational,
               :recovering,
               %EtherCAT.Master{runtime_faults: faults}
             )
  end

  test "activation_blocked retry enters recovering when activation failures clear but runtime faults remain" do
    start_supervised!(%{
      id: make_ref(),
      start: {FakeSlave, :start_link, [:sensor, :ok]}
    })

    faults = %{{:domain, :main} => {:cycle_invalid, :timeout}}

    data = %EtherCAT.Master{
      activation_failures: %{sensor: {:op, :no_response}},
      runtime_faults: faults
    }

    assert {:next_state, :recovering, %EtherCAT.Master{} = updated, _actions} =
             EtherCAT.Master.handle_event({:timeout, :retry}, nil, :activation_blocked, data)

    assert updated.activation_failures == %{}
    assert updated.runtime_faults == faults
  end

  test "domain cycle invalid enters recovering and recovery returns to running" do
    reason = {:wkc_mismatch, %{expected: 2, actual: 1}}

    assert {:next_state, :recovering, %EtherCAT.Master{} = recovering_data} =
             EtherCAT.Master.handle_event(
               :info,
               {:domain_cycle_invalid, :main, reason},
               :operational,
               %EtherCAT.Master{}
             )

    assert recovering_data.runtime_faults == %{{:domain, :main} => {:cycle_invalid, reason}}

    assert {:next_state, :operational, %EtherCAT.Master{runtime_faults: %{}}} =
             EtherCAT.Master.handle_event(
               :info,
               {:domain_cycle_recovered, :main},
               :recovering,
               recovering_data
             )
  end

  test "recovering retry restarts stopped domains once runtime faults remain" do
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

    data = %EtherCAT.Master{runtime_faults: %{{:domain, domain_id} => {:stopped, :down}}}

    assert {:keep_state, %EtherCAT.Master{} = recovering_data, _actions} =
             EtherCAT.Master.handle_event({:timeout, :retry}, nil, :recovering, data)

    assert recovering_data.runtime_faults == %{{:domain, domain_id} => {:stopped, :down}}
    assert {:ok, %{state: :cycling}} = Domain.info(domain_id)
  end

  test "recovering returns to idle for unrecoverable slave preop configuration failures" do
    data = %EtherCAT.Master{
      runtime_faults: %{
        {:slave, :outputs} =>
          {:preop, {:preop_configuration_failed, {:domain_reregister_required, 2, :main}}}
      }
    }

    assert {:next_state, :idle, %EtherCAT.Master{last_failure: failure}} =
             EtherCAT.Master.handle_event({:timeout, :retry}, nil, :recovering, data)

    assert failure.kind == :recovery_unrecoverable

    assert failure.reason ==
             {:slave_preop_configuration_failed, :outputs,
              {:domain_reregister_required, 2, :main}}
  end

  test "slave_reconnected authorizes reconnect through the master in recovering" do
    from = {self(), make_ref()}

    start_supervised!(%{
      id: make_ref(),
      start: {FakeSlave, :start_link, [:sensor, :ok]}
    })

    data =
      %EtherCAT.Master{
        runtime_faults: %{{:slave, :sensor} => {:down, :disconnected}},
        slaves: [{:sensor, 0x1001}]
      }

    assert {:keep_state, %EtherCAT.Master{} = updated} =
             EtherCAT.Master.handle_event(:info, {:slave_reconnected, :sensor}, :recovering, data)

    assert updated.runtime_faults == %{{:slave, :sensor} => {:reconnecting, :authorized}}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, {:runtime_degraded, _faults}}}]} =
             EtherCAT.Master.handle_event({:call, from}, :await_operational, :recovering, updated)
  end

  test "dc runtime failure enters recovering and clears on recovery" do
    data = %EtherCAT.Master{}

    assert {:next_state, :recovering, %EtherCAT.Master{} = recovering} =
             EtherCAT.Master.handle_event(
               :info,
               {:dc_runtime_failed, :timeout},
               :operational,
               data
             )

    assert recovering.runtime_faults == %{{:dc, :runtime} => {:failed, :timeout}}

    assert {:next_state, :operational, %EtherCAT.Master{runtime_faults: %{}}} =
             EtherCAT.Master.handle_event(
               :info,
               {:dc_runtime_recovered},
               :recovering,
               recovering
             )
  end

  test "dc lock loss is advisory by default" do
    data = %EtherCAT.Master{dc_config: %DCConfig{cycle_ns: 1_000_000, lock_policy: :advisory}}

    assert :keep_state_and_data =
             EtherCAT.Master.handle_event(
               :info,
               {:dc_lock_lost, :locking, 250},
               :operational,
               data
             )
  end

  test "dc lock loss can enter recovering independently of await_lock?" do
    data = %EtherCAT.Master{
      dc_config: %DCConfig{cycle_ns: 1_000_000, await_lock?: false, lock_policy: :recovering}
    }

    assert {:next_state, :recovering, %EtherCAT.Master{} = recovering} =
             EtherCAT.Master.handle_event(
               :info,
               {:dc_lock_lost, :locking, 250},
               :operational,
               data
             )

    assert recovering.runtime_faults == %{{:dc, :lock} => {:locking, 250}}

    assert {:next_state, :operational, %EtherCAT.Master{runtime_faults: %{}}} =
             EtherCAT.Master.handle_event(
               :info,
               {:dc_lock_regained, 42},
               :recovering,
               recovering
             )
  end

  test "dc lock loss can be fatal" do
    data = %EtherCAT.Master{dc_config: %DCConfig{cycle_ns: 1_000_000, lock_policy: :fatal}}

    assert {:next_state, :idle, %EtherCAT.Master{last_failure: failure}} =
             EtherCAT.Master.handle_event(
               :info,
               {:dc_lock_lost, :locking, 250},
               :operational,
               data
             )

    assert failure.kind == :dc_lock_lost
    assert failure.reason == {:locking, 250}
  end

  test "update_domain_cycle_time updates the live domain without mutating the master plan" do
    from = {self(), make_ref()}
    domain_id = :"master_domain_update_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, _pid} =
      start_supervised(
        {Domain, [id: domain_id, bus: self(), cycle_time_us: 1_000, miss_threshold: 500]}
      )

    data = %EtherCAT.Master{
      domain_configs: [
        %DomainPlan{id: domain_id, cycle_time_us: 1_000, miss_threshold: 500, logical_base: 0}
      ]
    }

    assert {:keep_state_and_data, [{:reply, ^from, :ok}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               {:update_domain_cycle_time, domain_id, 10_000},
               :operational,
               data
             )

    assert hd(data.domain_configs).cycle_time_us == 1_000
    assert {:ok, %{cycle_time_us: 10_000}} = Domain.info(domain_id)
  end

  test "update_domain_cycle_time rejects domains outside the master plan" do
    from = {self(), make_ref()}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, {:unknown_domain, :missing}}}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               {:update_domain_cycle_time, :missing, 10_000},
               :operational,
               %EtherCAT.Master{domain_configs: []}
             )
  end

  test "domains reports the live domain cycle time instead of the initial plan" do
    from = {self(), make_ref()}
    domain_id = :"master_domain_live_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, _pid} =
      start_supervised(
        {Domain, [id: domain_id, bus: self(), cycle_time_us: 1_000, miss_threshold: 500]}
      )

    :ok = Domain.update_cycle_time(domain_id, 10_000)

    assert {:keep_state_and_data, [{:reply, ^from, [{^domain_id, 10_000, _pid}]}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :domains,
               :operational,
               %EtherCAT.Master{
                 domain_configs: [
                   %DomainPlan{
                     id: domain_id,
                     cycle_time_us: 1_000,
                     miss_threshold: 500,
                     logical_base: 0
                   }
                 ]
               }
             )
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
               :discovering,
               %EtherCAT.Master{last_failure: failure}
             )
  end

  test "dc_status reports disabled when no DC config is present" do
    from = {self(), make_ref()}

    assert {:keep_state_and_data,
            [
              {:reply, ^from,
               %DCStatus{lock_state: :disabled, await_lock?: false, lock_policy: nil}}
            ]} =
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
      dc_config: %DCConfig{cycle_ns: 1_000_000, await_lock?: true, lock_policy: :recovering},
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
                 await_lock?: true,
                 lock_policy: :recovering,
                 reference_station: 0x1001,
                 reference_clock: :sensor,
                 lock_state: :inactive
               }}
            ]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :dc_status,
               :operational,
               data
             )
  end

  test "reference_clock and dc_runtime use dc runtime semantics" do
    from = {self(), make_ref()}

    data = %EtherCAT.Master{
      dc_config: %DCConfig{cycle_ns: 1_000_000},
      dc_ref_station: 0x1002,
      slaves: [{:thermo, 0x1002}]
    }

    assert {:keep_state_and_data, [{:reply, ^from, {:ok, %{name: :thermo, station: 0x1002}}}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :reference_clock,
               :operational,
               data
             )

    assert {:keep_state_and_data, [{:reply, ^from, {:error, :dc_inactive}}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :dc_runtime,
               :operational,
               data
             )
  end

  test "dc_status prefers the live dc runtime snapshot once active" do
    from = {self(), make_ref()}

    start_supervised!(%{
      id: make_ref(),
      start:
        {FakeDC, :start_link,
         [
           %DCStatus{
             configured?: true,
             active?: true,
             cycle_ns: 2_000_000,
             await_lock?: false,
             lock_policy: :advisory,
             reference_station: 0x1002,
             reference_clock: :runtime_ref,
             lock_state: :locked
           }
         ]}
    })

    data = %EtherCAT.Master{
      dc_config: %DCConfig{cycle_ns: 1_000_000, await_lock?: true, lock_policy: :fatal},
      dc_ref_station: 0x1001,
      slaves: [{:planned_ref, 0x1001}]
    }

    assert {:keep_state_and_data,
            [
              {:reply, ^from,
               %DCStatus{
                 configured?: true,
                 active?: true,
                 cycle_ns: 2_000_000,
                 await_lock?: false,
                 lock_policy: :advisory,
                 reference_station: 0x1002,
                 reference_clock: :planned_ref,
                 lock_state: :locked
               }}
            ]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :dc_status,
               :operational,
               data
             )
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
               :operational,
               %EtherCAT.Master{slaves: [{:sensor, 0x1001}]}
             )
  end

  test "slaves query follows registry restarts" do
    from = {self(), make_ref()}
    slave_name = :sensor_restart

    first =
      Agent.start_link(fn -> :ok end,
        name: {:via, Registry, {EtherCAT.Registry, {:slave, slave_name}}}
      )
      |> elem(1)

    assert {:keep_state_and_data,
            [
              {:reply, ^from,
               [
                 %{
                   pid: ^first,
                   server: {:via, Registry, {EtherCAT.Registry, {:slave, ^slave_name}}}
                 }
               ]}
            ]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :slaves,
               :operational,
               %EtherCAT.Master{slaves: [{slave_name, 0x1001}]}
             )

    Agent.stop(first)

    second =
      Agent.start_link(fn -> :ok end,
        name: {:via, Registry, {EtherCAT.Registry, {:slave, slave_name}}}
      )
      |> elem(1)

    on_exit(fn ->
      if Process.alive?(second) do
        Agent.stop(second)
      end
    end)

    assert {:keep_state_and_data,
            [
              {:reply, ^from,
               [
                 %{
                   pid: ^second,
                   server: {:via, Registry, {EtherCAT.Registry, {:slave, ^slave_name}}}
                 }
               ]}
            ]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :slaves,
               :operational,
               %EtherCAT.Master{slaves: [{slave_name, 0x1001}]}
             )
  end

  test "dc_runtime reports disabled and active states distinctly" do
    from = {self(), make_ref()}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, :dc_disabled}}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :dc_runtime,
               :preop_ready,
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
               :preop_ready,
               %EtherCAT.Master{dc_config: %DCConfig{}}
             )
  end
end
