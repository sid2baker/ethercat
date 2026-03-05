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

  test "domain_cycle_done/3 emits the domain done telemetry event" do
    handler_id = "ethercat-telemetry-test-#{System.unique_integer([:positive, :monotonic])}"
    event_name = [:ethercat, :domain, :cycle, :done]
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

    Telemetry.domain_cycle_done(:main, 42, 7)

    assert_receive {:telemetry_event, ^event_name, %{duration_us: 42, cycle_count: 7}, %{domain: :main}}
  end

  test "domain_cycle_missed/3 emits the domain missed telemetry event" do
    handler_id = "ethercat-telemetry-test-#{System.unique_integer([:positive, :monotonic])}"
    event_name = [:ethercat, :domain, :cycle, :missed]
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

    Telemetry.domain_cycle_missed(:main, 3, :no_response)

    assert_receive {:telemetry_event, ^event_name, %{miss_count: 3}, %{domain: :main, reason: :no_response}}
  end

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end
end
