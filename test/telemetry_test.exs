defmodule EtherCAT.TelemetryTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Telemetry

  test "dc_tick/2 emits the DC tick telemetry event" do
    handler_id = "ethercat-telemetry-test-#{System.unique_integer([:positive, :monotonic])}"
    event_name = [:ethercat, :dc, :tick]
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        event_name,
        &__MODULE__.handle_event/4,
        test_pid
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    Telemetry.dc_tick(0x1000, 3)

    assert_receive {:telemetry_event, ^event_name, %{wkc: 3}, %{ref_station: 0x1000}}
  end

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end
end
