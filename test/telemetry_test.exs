defmodule EtherCAT.TelemetryTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Telemetry

  test "submission_enqueued/4 emits the submission telemetry event" do
    event_name = [:ethercat, :bus, :submission, :enqueued]
    attach_event(event_name, self())

    Telemetry.submission_enqueued("eth0", :reliable, :awaiting, 3)

    assert_receive {:telemetry_event, ^event_name, %{queue_depth: 3},
                    %{link: "eth0", class: :reliable, state: :awaiting}}
  end

  test "submission_expired/3 emits the realtime expiry telemetry event" do
    event_name = [:ethercat, :bus, :submission, :expired]
    attach_event(event_name, self())

    Telemetry.submission_expired("eth0", :realtime, 125)

    assert_receive {:telemetry_event, ^event_name, %{age_us: 125},
                    %{link: "eth0", class: :realtime}}
  end

  test "dispatch_sent/4 emits the dispatch telemetry event" do
    event_name = [:ethercat, :bus, :dispatch, :sent]
    attach_event(event_name, self())

    Telemetry.dispatch_sent("eth0", :reliable, 2, 5)

    assert_receive {:telemetry_event, ^event_name, %{transaction_count: 2, datagram_count: 5},
                    %{link: "eth0", class: :reliable}}
  end

  test "link lifecycle emitters publish link events" do
    down_event = [:ethercat, :bus, :link, :down]
    reconnected_event = [:ethercat, :bus, :link, :reconnected]
    attach_event(down_event, self())
    attach_event(reconnected_event, self())

    Telemetry.link_down("eth0", :carrier_lost)
    Telemetry.link_reconnected("eth0")

    assert_receive {:telemetry_event, ^down_event, %{}, %{link: "eth0", reason: :carrier_lost}}

    assert_receive {:telemetry_event, ^reconnected_event, %{}, %{link: "eth0"}}
  end

  test "dc_tick/2 emits the DC tick telemetry event" do
    event_name = [:ethercat, :dc, :tick]
    attach_event(event_name, self())

    Telemetry.dc_tick(0x1000, 3)

    assert_receive {:telemetry_event, ^event_name, %{wkc: 3}, %{ref_station: 0x1000}}
  end

  test "domain_cycle_done/3 emits the domain done telemetry event" do
    event_name = [:ethercat, :domain, :cycle, :done]
    attach_event(event_name, self())

    Telemetry.domain_cycle_done(:main, 42, 7)

    assert_receive {:telemetry_event, ^event_name, %{duration_us: 42, cycle_count: 7},
                    %{domain: :main}}
  end

  test "domain_cycle_missed/3 emits the domain missed telemetry event" do
    event_name = [:ethercat, :domain, :cycle, :missed]
    attach_event(event_name, self())

    Telemetry.domain_cycle_missed(:main, 3, :no_response)

    assert_receive {:telemetry_event, ^event_name, %{miss_count: 3},
                    %{domain: :main, reason: :no_response}}
  end

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defp attach_event(event_name, pid) do
    handler_id = "ethercat-telemetry-test-#{System.unique_integer([:positive, :monotonic])}"

    :ok = :telemetry.attach(handler_id, event_name, &__MODULE__.handle_event/4, pid)

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)
  end
end
