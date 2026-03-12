defmodule EtherCAT.Integration.ScenarioTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Scenario
  alias EtherCAT.Simulator.Fault

  test "inject_fault_on_event/4 waits for the follow-up injection before the telemetry callback returns" do
    parent = self()

    Scenario.new()
    |> Scenario.inject_fault_on_event(
      [:ethercat, :integration, :scenario, :triggered],
      Fault.retreat_to_safeop(:outputs),
      inject_fun: fn _fault ->
        Process.sleep(40)
        send(parent, :trigger_injected)
        :ok
      end
    )
    |> Scenario.act("emit the trigger event", fn _ctx ->
      started_at = System.monotonic_time(:millisecond)

      :telemetry.execute([:ethercat, :integration, :scenario, :triggered], %{}, %{})

      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert elapsed_ms >= 30
      assert_received :trigger_injected
    end)
    |> Scenario.run()
  end
end
