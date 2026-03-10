defmodule EtherCAT.MasterRecoveryBusTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain
  alias EtherCAT.Domain.API, as: DomainAPI

  defmodule FakeBus do
    use GenServer

    def start_link({responses, info}) do
      GenServer.start_link(__MODULE__, {responses, info}, name: EtherCAT.Bus)
    end

    @impl true
    def init({responses, info}) do
      {:ok, %{responses: responses, info: info}}
    end

    @impl true
    def handle_call(
          {:transact, _tx, _deadline_us, _enqueued_at_us},
          _from,
          %{responses: [reply | rest]} = state
        ) do
      {:reply, reply, %{state | responses: rest}}
    end

    def handle_call(
          {:transact, _tx, _deadline_us, _enqueued_at_us},
          _from,
          %{responses: []} = state
        ) do
      {:reply, {:ok, [%{data: <<0>>, wkc: 1, circular: false, irq: 0}]}, state}
    end

    def handle_call(:info, _from, %{info: info} = state) do
      {:reply, {:ok, info}, state}
    end
  end

  test "recovering retry does not restart stopped domains while the bus is down" do
    domain_id = :"master_domain_retry_#{System.unique_integer([:positive, :monotonic])}"

    bus =
      start_supervised!(
        {FakeBus,
         {List.duplicate({:ok, [%{data: <<0>>, wkc: 1, circular: false, irq: 0}]}, 8),
          %{state: :idle, carrier_up: false}}}
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
             EtherCAT.Master.handle_event({:timeout, :retry}, nil, :recovering, data)

    assert recovering_data.runtime_faults == %{{:domain, domain_id} => {:stopped, :down}}
    assert {:ok, %{state: :stopped}} = DomainAPI.info(domain_id)
  end
end
