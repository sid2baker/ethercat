defmodule EtherCAT.Integration.Simulator.CorruptedFrameTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator.Udp
  alias EtherCAT.Simulator.Udp.Fault, as: UdpFault

  import EtherCAT.Integration.Assertions

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    SimulatorRing.boot_operational!(
      start_opts: [frame_timeout_ms: 10],
      await_operational_ms: 3_000
    )

    attach_event([:ethercat, :bus, :frame, :dropped], self())
    :ok
  end

  test "truncating the next UDP reply is dropped as a decode error and the master recovers" do
    assert_corrupted_reply_recovery(:truncate, :decode_error)
  end

  test "mutating the next UDP reply idx is dropped as an index mismatch and the master recovers" do
    assert_corrupted_reply_recovery(:wrong_idx, :idx_mismatch)
  end

  test "rewriting the next UDP reply type is dropped as a decode error and the master recovers" do
    assert_corrupted_reply_recovery(:unsupported_type, :decode_error)
  end

  test "replaying the previous UDP reply is dropped as an index mismatch and the master recovers" do
    assert {:ok, %{last_response_captured?: true}} = Udp.info()
    assert_corrupted_reply_recovery(:replay_previous, :idx_mismatch)
  end

  test "counted corruption windows apply the same UDP reply mutation more than once" do
    {:ok, %{total_miss_count: before_miss_count}} = EtherCAT.domain_info(:main)

    assert :ok = Udp.inject_fault(UdpFault.truncate() |> UdpFault.next(2))

    assert_receive_frame_dropped(:decode_error)
    assert_receive_frame_dropped(:decode_error)

    assert_eventually(
      fn ->
        assert {:ok, %{next_fault: nil, pending_faults: []}} = Udp.info()
      end,
      80
    )

    assert_eventually(
      fn ->
        assert {:ok, %{last_invalid_reason: :timeout, total_miss_count: after_miss_count}} =
                 EtherCAT.domain_info(:main)

        assert after_miss_count >= before_miss_count + 2
      end,
      80
    )

    assert_eventually(
      fn ->
        assert :operational = EtherCAT.state()
        assert {:ok, %{cycle_health: :healthy}} = EtherCAT.domain_info(:main)
      end,
      80
    )
  end

  test "scripted corruption windows apply successive UDP reply mutations in order" do
    assert :ok =
             Udp.inject_fault(
               UdpFault.script([UdpFault.unsupported_type(), UdpFault.replay_previous()])
             )

    assert_receive_frame_dropped(:decode_error)
    assert_receive_frame_dropped(:idx_mismatch)

    assert_eventually(
      fn ->
        assert {:ok, %{next_fault: nil, pending_faults: []}} = Udp.info()
        assert :operational = EtherCAT.state()
        assert {:ok, %{cycle_health: :healthy}} = EtherCAT.domain_info(:main)
      end,
      80
    )
  end

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defp assert_corrupted_reply_recovery(mode, telemetry_reason) do
    {:ok, %{total_miss_count: before_miss_count}} = EtherCAT.domain_info(:main)

    fault =
      case mode do
        :truncate -> UdpFault.truncate()
        :unsupported_type -> UdpFault.unsupported_type()
        :wrong_idx -> UdpFault.wrong_idx()
        :replay_previous -> UdpFault.replay_previous()
      end

    assert :ok = Udp.inject_fault(fault)

    assert_receive_frame_dropped(telemetry_reason)

    assert_eventually(
      fn ->
        assert {:ok, %{next_fault: nil, pending_faults: []}} = Udp.info()
      end,
      80
    )

    assert_eventually(
      fn ->
        assert {:ok, %{last_invalid_reason: :timeout, total_miss_count: after_miss_count}} =
                 EtherCAT.domain_info(:main)

        assert after_miss_count > before_miss_count
      end,
      80
    )

    assert_eventually(
      fn ->
        assert :operational = EtherCAT.state()
        assert {:ok, %{cycle_health: :healthy}} = EtherCAT.domain_info(:main)
      end,
      80
    )
  end

  defp assert_receive_frame_dropped(reason) do
    assert_receive {:telemetry_event, [:ethercat, :bus, :frame, :dropped], %{size: size},
                    %{reason: ^reason}},
                   1_000

    assert size > 0
  end

  defp attach_event(event_name, pid) do
    handler_id =
      "ethercat-integration-telemetry-#{System.unique_integer([:positive, :monotonic])}"

    :ok = :telemetry.attach(handler_id, event_name, &__MODULE__.handle_event/4, pid)

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)
  end
end
