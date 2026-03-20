defmodule EtherCAT.Integration.Simulator.CorruptedFrameTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Integration.Trace
  alias EtherCAT.Simulator.Transport.Udp
  alias EtherCAT.Simulator.Transport.Udp.Fault, as: UdpFault

  setup do
    SimulatorRing.boot_operational!(
      start_opts: [frame_timeout_ms: 10],
      await_operational_ms: 3_000
    )

    trace = Trace.start_capture()

    on_exit(fn ->
      Trace.stop(trace)
      SimulatorRing.stop_all!()
    end)

    {:ok, trace: trace}
  end

  test "truncating the next UDP reply is dropped as a decode error and the master recovers",
       %{trace: trace} do
    assert_corrupted_reply_recovery(:truncate, :decode_error, trace)
  end

  test "mutating the next UDP reply idx is dropped as an index mismatch and the master recovers",
       %{trace: trace} do
    assert_corrupted_reply_recovery(:wrong_idx, :idx_mismatch, trace)
  end

  test "rewriting the next UDP reply type is dropped as a decode error and the master recovers",
       %{trace: trace} do
    assert_corrupted_reply_recovery(:unsupported_type, :decode_error, trace)
  end

  test "replaying the previous UDP reply is dropped as an index mismatch and the master recovers",
       %{trace: trace} do
    assert {:ok, %{last_response_captured?: true}} = Udp.info()
    assert_corrupted_reply_recovery(:replay_previous, :idx_mismatch, trace)
  end

  test "counted corruption windows apply the same UDP reply mutation more than once", %{
    trace: trace
  } do
    {:ok, %{total_miss_count: before_miss_count}} = EtherCAT.Diagnostics.domain_info(:main)

    assert :ok = Udp.inject_fault(UdpFault.truncate() |> UdpFault.next(2))

    Expect.eventually(
      fn ->
        Expect.trace_event(trace, [:ethercat, :bus, :frame, :dropped],
          measurements: [size: &(&1 > 0)],
          metadata: [reason: :decode_error]
        )
      end,
      attempts: 50
    )

    Expect.eventually(
      fn ->
        assert length(frame_dropped_events(trace, :decode_error)) >= 2
      end,
      attempts: 80
    )

    Expect.eventually(
      fn ->
        Expect.simulator_queue_empty()
      end,
      attempts: 80
    )

    Expect.eventually(
      fn ->
        Expect.domain(:main,
          last_invalid_reason: :timeout,
          total_miss_count: &(&1 >= before_miss_count + 2)
        )
      end,
      attempts: 80
    )

    Expect.eventually(
      fn ->
        Expect.master_state(:operational)
        Expect.domain(:main, cycle_health: :healthy)
      end,
      attempts: 80
    )
  end

  test "scripted corruption windows apply successive UDP reply mutations in order", %{
    trace: trace
  } do
    assert :ok =
             Udp.inject_fault(
               UdpFault.script([UdpFault.unsupported_type(), UdpFault.replay_previous()])
             )

    Expect.eventually(
      fn ->
        assert length(frame_dropped_events(trace, :decode_error)) >= 1
        assert length(frame_dropped_events(trace, :idx_mismatch)) >= 1
      end,
      attempts: 80
    )

    Expect.eventually(
      fn ->
        Expect.simulator_queue_empty()
        Expect.master_state(:operational)
        Expect.domain(:main, cycle_health: :healthy)
      end,
      attempts: 80
    )
  end

  defp assert_corrupted_reply_recovery(mode, telemetry_reason, trace) do
    {:ok, %{total_miss_count: before_miss_count}} = EtherCAT.Diagnostics.domain_info(:main)

    fault =
      case mode do
        :truncate -> UdpFault.truncate()
        :unsupported_type -> UdpFault.unsupported_type()
        :wrong_idx -> UdpFault.wrong_idx()
        :replay_previous -> UdpFault.replay_previous()
      end

    assert :ok = Udp.inject_fault(fault)

    Expect.eventually(
      fn ->
        Expect.trace_event(trace, [:ethercat, :bus, :frame, :dropped],
          measurements: [size: &(&1 > 0)],
          metadata: [reason: telemetry_reason]
        )
      end,
      attempts: 50
    )

    Expect.eventually(
      fn ->
        Expect.simulator_queue_empty()
      end,
      attempts: 80
    )

    Expect.eventually(
      fn ->
        Expect.domain(:main,
          last_invalid_reason: :timeout,
          total_miss_count: &(&1 > before_miss_count)
        )
      end,
      attempts: 80
    )

    Expect.eventually(
      fn ->
        Expect.master_state(:operational)
        Expect.domain(:main, cycle_health: :healthy)
      end,
      attempts: 80
    )
  end

  defp frame_dropped_events(trace, reason) do
    trace
    |> Trace.snapshot()
    |> Enum.filter(fn
      %{
        kind: :telemetry,
        event: [:ethercat, :bus, :frame, :dropped],
        metadata: %{reason: ^reason},
        measurements: %{size: size}
      } ->
        size > 0

      _entry ->
        false
    end)
  end
end
