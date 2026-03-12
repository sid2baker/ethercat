defmodule EtherCAT.Integration.Simulator.CommandTargetedWKCMismatchTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

  import EtherCAT.Integration.Assertions

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    SimulatorRing.boot_operational!(
      slave_config_opts: [output_health_poll_ms: 20],
      await_operational_ms: 2_500
    )

    attach_event([:ethercat, :slave, :down], self())

    :ok
  end

  test "command-targeted fprd skew drives slave-down recovery while logical PDO traffic stays healthy" do
    assert :ok = Simulator.inject_fault(Fault.command_wkc_offset(:fprd, -1) |> Fault.next(100))

    assert_receive {:telemetry_event, [:ethercat, :slave, :down], %{},
                    %{slave: :outputs, station: 0x1002}},
                   1_500

    assert_eventually(
      fn ->
        assert {:ok, %{cycle_health: :healthy}} = EtherCAT.domain_info(:main)
        assert {:ok, %{al_state: :op}} = EtherCAT.slave_info(:outputs)
      end,
      120
    )

    assert_eventually(
      fn ->
        assert {:ok, %{next_fault: nil, pending_faults: []}} = Simulator.info()
        assert :operational = EtherCAT.state()
        assert nil == SimulatorRing.fault_for(:outputs)
        assert {:ok, %{cycle_health: :healthy}} = EtherCAT.domain_info(:main)
        assert {:ok, %{al_state: :op}} = EtherCAT.slave_info(:outputs)
      end,
      200
    )
  end

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defp attach_event(event_name, pid) do
    handler_id =
      "ethercat-command-wkc-#{System.unique_integer([:positive, :monotonic])}"

    :ok = :telemetry.attach(handler_id, event_name, &__MODULE__.handle_event/4, pid)

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)
  end
end
