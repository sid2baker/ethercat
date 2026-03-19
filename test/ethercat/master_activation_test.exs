defmodule EtherCAT.MasterActivationTest do
  use ExUnit.Case, async: false

  alias EtherCAT.DC.Config, as: DCConfig
  alias EtherCAT.Domain
  alias EtherCAT.Domain, as: DomainAPI
  alias EtherCAT.Master
  alias EtherCAT.Master.Activation
  alias EtherCAT.Master.Config.DomainPlan
  alias EtherCAT.TestSupport.FakeBus

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
end
