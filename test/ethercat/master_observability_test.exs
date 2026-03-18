defmodule EtherCAT.MasterObservabilityTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Master
  alias EtherCAT.Master.Activation
  alias EtherCAT.TestSupport.FakeBus

  @activation_result_event [:ethercat, :master, :activation, :result]
  @startup_bus_stable_event [:ethercat, :master, :startup, :bus_stable]
  @configuration_result_event [:ethercat, :master, :configuration, :result]

  setup do
    handler_id = "master-observability-#{System.unique_integer([:positive, :monotonic])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [@activation_result_event, @startup_bus_stable_event, @configuration_result_event],
        &__MODULE__.handle_telemetry_event/4,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      case Process.whereis(EtherCAT.Bus) do
        pid when is_pid(pid) ->
          Process.exit(pid, :shutdown)

        nil ->
          :ok
      end
    end)

    :ok
  end

  test "discovering emits startup and configuration telemetry from the real master producer path" do
    start_supervised!(
      {FakeBus,
       [
         name: EtherCAT.Bus,
         responses: [{:ok, [%{data: <<>>, wkc: 32_770, circular: false, irq: 0}]}],
         info: %{state: :idle}
       ]}
    )

    now_ms = System.monotonic_time(:millisecond)

    data = %Master{
      scan_window: [{now_ms - 1, 32_770}],
      scan_stable_ms: 0,
      scan_poll_ms: 1,
      base_station: 0
    }

    assert {:next_state, :idle, %Master{last_failure: failure}} =
             Master.FSM.handle_event({:timeout, :scan_poll}, nil, :discovering, data)

    assert failure.kind == :configuration_failed

    assert_receive {:telemetry_event, @startup_bus_stable_event, %{slave_count: 32_770}, %{}}

    assert_receive {:telemetry_event, @configuration_result_event, %{duration_ms: duration_ms},
                    %{
                      status: :error,
                      slave_count: 32_770,
                      runtime_target: :op,
                      reason: :unsupported_topology
                    }}

    assert duration_ms >= 0
  end

  test "activation emits result telemetry from the real activation producer path" do
    start_supervised!(
      {FakeBus,
       [
         name: EtherCAT.Bus,
         responses: [{:ok, [%{wkc: 1}]}],
         info: %{state: :idle}
       ]}
    )

    assert {:ok, :preop_ready, _updated} =
             Activation.activate_network(%Master{
               activatable_slaves: [],
               desired_runtime_target: :preop
             })

    assert_receive {:telemetry_event, @activation_result_event, %{duration_ms: duration_ms},
                    %{status: :ok, runtime_target: :preop, blocked_count: 0, reason: nil}}

    assert duration_ms >= 0
  end

  def handle_telemetry_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end
end
