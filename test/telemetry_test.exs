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

    Telemetry.link_down("eth0|eth1", "eth0", :carrier_lost)
    Telemetry.link_reconnected("eth0|eth1", "eth0")

    assert_receive {:telemetry_event, ^down_event, %{},
                    %{link: "eth0|eth1", endpoint: "eth0", reason: :carrier_lost}}

    assert_receive {:telemetry_event, ^reconnected_event, %{},
                    %{link: "eth0|eth1", endpoint: "eth0"}}
  end

  test "dc_tick/2 emits the DC tick telemetry event" do
    event_name = [:ethercat, :dc, :tick]
    attach_event(event_name, self())

    Telemetry.dc_tick(0x1000, 3)

    assert_receive {:telemetry_event, ^event_name, %{wkc: 3}, %{ref_station: 0x1000}}
  end

  test "dc_sync_diff_observed/3 emits the DC sync-diff telemetry event" do
    event_name = [:ethercat, :dc, :sync_diff, :observed]
    attach_event(event_name, self())

    Telemetry.dc_sync_diff_observed(0x1000, 42, 3)

    assert_receive {:telemetry_event, ^event_name, %{max_sync_diff_ns: 42},
                    %{ref_station: 0x1000, station_count: 3}}
  end

  test "dc_lock_changed/4 emits the DC lock transition telemetry event" do
    event_name = [:ethercat, :dc, :lock, :changed]
    attach_event(event_name, self())

    Telemetry.dc_lock_changed(0x1000, :locking, :locked, 15)

    assert_receive {:telemetry_event, ^event_name, %{},
                    %{ref_station: 0x1000, from: :locking, to: :locked, max_sync_diff_ns: 15}}
  end

  test "dc_runtime_state_changed/4 emits the DC runtime lifecycle event" do
    event_name = [:ethercat, :dc, :runtime, :state, :changed]
    attach_event(event_name, self())

    Telemetry.dc_runtime_state_changed(:healthy, :failing, {:sync_diff_read_failed, 0x1001}, 3)

    assert_receive {:telemetry_event, ^event_name, %{},
                    %{
                      from: :healthy,
                      to: :failing,
                      reason: :sync_diff_read_failed,
                      consecutive_failures: 3
                    }}
  end

  test "domain_cycle_done/4 emits the domain done telemetry event" do
    event_name = [:ethercat, :domain, :cycle, :done]
    attach_event(event_name, self())

    Telemetry.domain_cycle_done(:main, 42, 7, 99)

    assert_receive {:telemetry_event, ^event_name,
                    %{duration_us: 42, cycle_count: 7, completed_at_us: 99}, %{domain: :main}}
  end

  test "domain_cycle_missed/5 emits the domain missed telemetry event" do
    event_name = [:ethercat, :domain, :cycle, :missed]
    attach_event(event_name, self())

    Telemetry.domain_cycle_missed(:main, 3, 8, {:wkc_mismatch, %{expected: 4, actual: 2}}, 123)

    assert_receive {:telemetry_event, ^event_name,
                    %{miss_count: 3, total_miss_count: 8, invalid_at_us: 123},
                    %{
                      domain: :main,
                      reason: :wkc_mismatch,
                      expected_wkc: 4,
                      actual_wkc: 2,
                      reply_count: 1
                    }}
  end

  test "master_state_changed/4 emits the master lifecycle event" do
    event_name = [:ethercat, :master, :state, :changed]
    attach_event(event_name, self())

    Telemetry.master_state_changed(:awaiting_preop, :preop_ready, :preop_ready, :preop)

    assert_receive {:telemetry_event, ^event_name, %{},
                    %{
                      from: :awaiting_preop,
                      to: :preop_ready,
                      public_state: :preop_ready,
                      runtime_target: :preop
                    }}
  end

  test "master_slave_fault_changed/3 emits the master slave fault lifecycle event" do
    event_name = [:ethercat, :master, :slave_fault, :changed]
    attach_event(event_name, self())

    Telemetry.master_slave_fault_changed(:mailbox, {:preop, :failed}, nil)

    assert_receive {:telemetry_event, ^event_name, %{}, %{slave: :mailbox, from: :preop, to: nil}}
  end

  test "slave_startup_retry/6 emits the startup retry event" do
    event_name = [:ethercat, :slave, :startup, :retry]
    attach_event(event_name, self())

    Telemetry.slave_startup_retry(:inputs, 0x1001, :sii_read, :no_response, 2, 200)

    assert_receive {:telemetry_event, ^event_name, %{retry_count: 2, retry_delay_ms: 200},
                    %{slave: :inputs, station: 0x1001, phase: :sii_read, reason: :no_response}}
  end

  test "events/0 exposes the canonical attach_many event list" do
    handler_id = "ethercat-telemetry-many-#{System.unique_integer([:positive, :monotonic])}"

    :ok =
      :telemetry.attach_many(handler_id, Telemetry.events(), &__MODULE__.handle_event/4, self())

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    Telemetry.domain_cycle_done(:main, 42, 7, 99)

    assert_receive {:telemetry_event, [:ethercat, :domain, :cycle, :done],
                    %{duration_us: 42, cycle_count: 7, completed_at_us: 99}, %{domain: :main}}
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
