defmodule EtherCAT.Integration.Simulator.RedundantPrimaryRestoreRaceTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Trace
  alias EtherCAT.IntegrationSupport.{RedundantSimulatorRing, SimulatorRing}

  @domain_cycle_invalid_event [:ethercat, :domain, :cycle, :invalid]
  @domain_cycle_transport_miss_event [:ethercat, :domain, :cycle, :transport_miss]
  @master_state_changed_event [:ethercat, :master, :state, :changed]

  setup do
    _ = safe_reconnect_primary()
    trace = Trace.start_capture()

    on_exit(fn ->
      _ = safe_reconnect_primary()
      Trace.stop(trace)
      SimulatorRing.stop_all!()
    end)

    %{trace: trace}
  end

  @tag :raw_socket_redundant_toggle
  test "primary veth restore does not invalidate cycles after degraded operation", %{trace: trace} do
    assert %{transport: :raw_redundant} = RedundantSimulatorRing.boot_operational!()

    assert_loopback_io()

    assert :ok = RedundantSimulatorRing.disconnect_primary!()

    Expect.eventually(
      fn ->
        assert {:ok, %{type: :redundant}} = EtherCAT.Bus.info(EtherCAT.Bus)

        Expect.master_state(:operational)
        Expect.domain(:main, cycle_health: :healthy)
      end,
      trace: trace,
      label: "primary disconnect degraded path"
    )

    Trace.note(trace, "primary reconnect start")
    assert :ok = RedundantSimulatorRing.reconnect_primary!()

    Expect.eventually(
      fn ->
        assert {:ok, %{type: :redundant}} = EtherCAT.Bus.info(EtherCAT.Bus)
      end,
      trace: trace,
      label: "primary reconnect reestablishes redundant path"
    )

    Expect.eventually(
      fn ->
        assert {:ok, %{type: :redundant}} = EtherCAT.Bus.info(EtherCAT.Bus)

        Expect.master_state(:operational)
        Expect.domain(:main, cycle_health: :healthy)
        assert_loopback_io()
      end,
      trace: trace,
      label: "primary reconnect returns healthy"
    )

    Expect.stays(fn ->
      assert {:ok, %{type: :redundant}} = EtherCAT.Bus.info(EtherCAT.Bus)
      Expect.master_state(:operational)
      Expect.domain(:main, cycle_health: :healthy)
    end)

    assert_no_reconnect_faults(trace, "primary reconnect start")
  end

  defp assert_loopback_io do
    assert :ok = EtherCAT.write_output(:outputs, :ch1, 1)
    assert :ok = EtherCAT.write_output(:outputs, :ch16, 1)

    Expect.eventually(fn ->
      Expect.master_state(:operational)
      Expect.domain(:main, cycle_health: :healthy)

      assert {:ok, {1, ch1_updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
      assert is_integer(ch1_updated_at_us)

      assert {:ok, {1, ch16_updated_at_us}} = EtherCAT.read_input(:inputs, :ch16)
      assert is_integer(ch16_updated_at_us)

      Expect.signal(:outputs, :ch1, value: true)
      Expect.signal(:outputs, :ch16, value: true)
    end)
  end

  defp assert_no_reconnect_faults(%Trace{} = trace, label) do
    note_at_ms = note_timestamp!(trace, label)

    reconnect_faults =
      trace
      |> Trace.snapshot()
      |> Enum.filter(&fault_after_reconnect?(&1, note_at_ms))

    assert reconnect_faults == [],
           """
           expected primary reconnect to avoid domain invalid/transport-miss or master recovering transitions

           #{Trace.format(trace, title: "Reconnect trace", limit: 300)}
           """
  end

  defp note_timestamp!(%Trace{} = trace, label) do
    trace
    |> Trace.snapshot()
    |> Enum.find_value(fn
      %{kind: :note, label: ^label, at_ms: at_ms} -> at_ms
      _other -> nil
    end)
    |> case do
      nil -> flunk("expected trace note #{inspect(label)} to exist")
      at_ms -> at_ms
    end
  end

  defp fault_after_reconnect?(
         %{kind: :telemetry, at_ms: at_ms, event: event},
         note_at_ms
       )
       when at_ms >= note_at_ms and
              event in [@domain_cycle_invalid_event, @domain_cycle_transport_miss_event] do
    true
  end

  defp fault_after_reconnect?(
         %{
           kind: :telemetry,
           at_ms: at_ms,
           event: @master_state_changed_event,
           metadata: metadata
         },
         note_at_ms
       )
       when at_ms >= note_at_ms do
    metadata.to == :recovering
  end

  defp fault_after_reconnect?(_entry, _note_at_ms), do: false

  defp safe_reconnect_primary do
    RedundantSimulatorRing.reconnect_primary!()
  rescue
    _error -> :ok
  end
end
