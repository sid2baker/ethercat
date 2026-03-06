defmodule EtherCAT.MasterTest do
  use ExUnit.Case, async: true

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
end
