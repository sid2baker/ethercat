defmodule EtherCAT.Integration.Simulator.SafeOpRetreatWithHealthPollTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

  import EtherCAT.Integration.Assertions

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    SimulatorRing.boot_operational!(
      slave_config_opts: [output_health_poll_ms: 20],
      start_opts: [frame_timeout_ms: 10],
      await_operational_ms: 2_500
    )

    attach_event([:ethercat, :slave, :health, :fault], self())

    :ok
  end

  test "safeop retreat stays slave-local and is retried back to op" do
    assert :ok = Simulator.inject_fault(Fault.retreat_to_safeop(:outputs))

    assert_receive {:telemetry_event, [:ethercat, :slave, :health, :fault],
                    %{al_state: 4, error_code: 0}, %{slave: :outputs, station: 0x1002}},
                   1_000

    assert_eventually(
      fn ->
        assert {:retreated, :safeop} = SimulatorRing.fault_for(:outputs)
        assert :operational = EtherCAT.state()
        assert {:ok, %{cycle_health: :healthy}} = EtherCAT.domain_info(:main)
        assert {:ok, %{al_state: :safeop}} = EtherCAT.slave_info(:outputs)
      end,
      80
    )

    assert_stays(
      fn ->
        assert :operational = EtherCAT.state()
        assert {:ok, %{cycle_health: :healthy}} = EtherCAT.domain_info(:main)
      end,
      10
    )

    assert_eventually(
      fn ->
        assert nil == SimulatorRing.fault_for(:outputs)
        assert :operational = EtherCAT.state()
        assert {:ok, %{al_state: :op}} = EtherCAT.slave_info(:outputs)
        assert {:ok, %{cycle_health: :healthy}} = EtherCAT.domain_info(:main)
      end,
      120
    )
  end

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defp attach_event(event_name, pid) do
    handler_id =
      "ethercat-safeop-health-#{System.unique_integer([:positive, :monotonic])}"

    :ok = :telemetry.attach(handler_id, event_name, &__MODULE__.handle_event/4, pid)

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)
  end
end
