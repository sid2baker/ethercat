defmodule EtherCAT.MasterTest do
  use ExUnit.Case, async: true

  alias EtherCAT.DC.Config, as: DCConfig
  alias EtherCAT.DC.Status, as: DCStatus

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
      slaves: [{:sensor, 0x1001, self()}]
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
      slaves: [{:thermo, 0x1002, self()}]
    }

    assert {:keep_state_and_data, [{:reply, ^from, {:ok, %{name: :thermo, station: 0x1002}}}]} =
             EtherCAT.Master.handle_event({:call, from}, :reference_clock, :running, data)

    assert {:keep_state_and_data, [{:reply, ^from, {:error, :dc_inactive}}]} =
             EtherCAT.Master.handle_event({:call, from}, :dc_runtime, :running, data)
  end

  test "dc_runtime reports disabled and active states distinctly" do
    from = {self(), make_ref()}
    dc_pid = self()

    assert {:keep_state_and_data, [{:reply, ^from, {:error, :dc_disabled}}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :dc_runtime,
               :running,
               %EtherCAT.Master{}
             )

    assert {:keep_state_and_data, [{:reply, ^from, {:ok, ^dc_pid}}]} =
             EtherCAT.Master.handle_event(
               {:call, from},
               :dc_runtime,
               :running,
               %EtherCAT.Master{dc_pid: dc_pid, dc_config: %DCConfig{}}
             )
  end
end
