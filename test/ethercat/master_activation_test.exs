defmodule EtherCAT.MasterActivationTest do
  use ExUnit.Case, async: false

  alias EtherCAT.DC.Config, as: DCConfig
  alias EtherCAT.Domain
  alias EtherCAT.Domain, as: DomainAPI
  alias EtherCAT.Master
  alias EtherCAT.Master.Activation
  alias EtherCAT.Master.Config.DomainPlan
  alias EtherCAT.TestSupport.FakeBus

  defmodule FakeSlave do
    @behaviour :gen_statem

    def start_link(name, owner \\ nil) do
      :gen_statem.start_link(
        {:via, Registry, {EtherCAT.Registry, {:slave, name}}},
        __MODULE__,
        %{owner: owner, health_poll_ms: nil},
        []
      )
    end

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(data), do: {:ok, :preop, data}

    @impl true
    def handle_event({:call, from}, :info, :preop, data) do
      {:keep_state, data, [{:reply, from, {:ok, %{al_state: :preop, configuration_error: nil}}}]}
    end

    def handle_event({:call, from}, {:configure, opts}, :preop, data) do
      if is_pid(data.owner) do
        send(data.owner, {:configured, self(), opts})
      end

      {:keep_state,
       %{data | health_poll_ms: Keyword.get(opts, :health_poll_ms, data.health_poll_ms)},
       [{:reply, from, :ok}]}
    end

    def handle_event({:call, from}, {:request, target}, _state, _data)
        when target in [:preop, :safeop, :op] do
      {:keep_state_and_data, [{:reply, from, :ok}]}
    end

    def handle_event(_type, _event, _state, data), do: {:keep_state, data}
  end

  setup do
    on_exit(fn ->
      case Process.whereis(EtherCAT.DC) do
        pid when is_pid(pid) ->
          DynamicSupervisor.terminate_child(EtherCAT.SessionSupervisor, pid)

        nil ->
          :ok
      end

      case Process.whereis(EtherCAT.Bus) do
        pid when is_pid(pid) ->
          Process.exit(pid, :shutdown)

        nil ->
          :ok
      end
    end)

    :ok
  end

  test "activation failure rolls back started domain cycles and dc runtime" do
    domain_id = :"activation_domain_#{System.unique_integer([:positive, :monotonic])}"
    missing_domain_id = :"missing_domain_#{System.unique_integer([:positive, :monotonic])}"

    start_supervised!({FakeBus, [name: EtherCAT.Bus]})

    {:ok, _pid} =
      start_supervised(
        {Domain, [id: domain_id, bus: self(), cycle_time_us: 1_000, miss_threshold: 500]}
      )

    assert {:ok, 0} = DomainAPI.register_pdo(domain_id, {:sensor, {:sm, 0}}, 1, :input)

    data = %Master{
      activatable_slaves: [:sensor],
      dc_ref_station: 0x1000,
      dc_stations: [0x1000],
      dc_config: %DCConfig{cycle_ns: 100_000_000, await_lock?: false},
      domain_configs: [
        %DomainPlan{
          id: domain_id,
          cycle_time_us: 1_000,
          miss_threshold: 500,
          recovery_threshold: 3,
          logical_base: 0
        },
        %DomainPlan{
          id: missing_domain_id,
          cycle_time_us: 1_000,
          miss_threshold: 500,
          recovery_threshold: 3,
          logical_base: 1
        }
      ]
    }

    assert {:error, {:domain_cycle_start_failed, ^missing_domain_id, :not_found}, failed_data} =
             Activation.activate_network(data)

    assert failed_data.dc_ref == nil
    assert Process.whereis(EtherCAT.DC) == nil
    assert {:ok, %{state: :stopped}} = DomainAPI.info(domain_id)
  end

  test "activate from preop_ready restores the desired runtime target to op" do
    from = {self(), make_ref()}

    start_supervised!({FakeBus, [name: EtherCAT.Bus]})

    start_supervised!(%{
      id: make_ref(),
      start: {FakeSlave, :start_link, [:sensor]}
    })

    data = %Master{
      desired_runtime_target: :preop,
      activatable_slaves: [:sensor]
    }

    assert {:next_state, :operational, %Master{} = updated, [{:reply, ^from, :ok}]} =
             EtherCAT.Master.FSM.handle_event({:call, from}, :activate, :preop_ready, data)

    assert updated.desired_runtime_target == :op
    assert updated.activation_failures == %{}
  end

  test "activation restores configured health polling for held preop slaves" do
    start_supervised!({FakeBus, [name: EtherCAT.Bus]})

    coupler =
      start_supervised!(%{
        id: make_ref(),
        start: {FakeSlave, :start_link, [:coupler]}
      })

    mailbox =
      start_supervised!(%{
        id: make_ref(),
        start: {FakeSlave, :start_link, [:mailbox, self()]}
      })

    data = %Master{
      desired_runtime_target: :op,
      activatable_slaves: [:coupler],
      slave_configs: [
        %EtherCAT.Slave.Config{name: :coupler, target_state: :op},
        %EtherCAT.Slave.Config{name: :mailbox, target_state: :preop, health_poll_ms: 20}
      ]
    }

    assert {:ok, :operational, %Master{} = updated} = Activation.activate_network(data)

    assert_receive {:configured, ^mailbox, [health_poll_ms: 20]}
    refute_receive {:configured, ^coupler, _opts}
    assert updated.activation_failures == %{}
  end
end
