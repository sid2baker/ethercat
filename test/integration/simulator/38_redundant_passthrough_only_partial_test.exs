defmodule EtherCAT.Integration.Simulator.RedundantPassthroughOnlyPartialTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.IntegrationSupport.{RedundantSimulatorRing, SimulatorRing}
  alias EtherCAT.Simulator.Transport.Raw
  alias EtherCAT.Simulator.Transport.Raw.Fault, as: RawFault

  setup do
    on_exit(fn ->
      SimulatorRing.stop_all!()
    end)

    :ok
  end

  @tag :raw_socket_redundant
  test "redundant raw bus returns passthrough data and degrades when processed copy is delayed" do
    endpoint = RedundantSimulatorRing.start_simulator!()

    bus_name =
      :"redundant_passthrough_only_partial_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, bus} =
      Bus.start_link(
        name: bus_name,
        interface: endpoint.master_primary_interface,
        backup_interface: endpoint.master_secondary_interface,
        frame_timeout_ms: 40
      )

    on_exit(fn ->
      if Process.alive?(bus) do
        GenServer.stop(bus)
      end
    end)

    baseline_wkc = wait_until_bus_ready!(bus_name)
    assert baseline_wkc > 0

    # Delay every response emitted by the simulator's secondary endpoint by
    # 200ms. For a fixed-station read to the right-most slave in the healthy
    # ring, the authoritative forward-path response exits secondary while the
    # reverse-path copy still exits primary as passthrough-only traffic.
    assert :ok =
             Raw.inject_fault(RawFault.delay_response(200, endpoint: :secondary))

    # The passthrough-only response (wkc=0, unchanged payload) is not
    # authoritative enough to complete the exchange. The real processed
    # response is delayed beyond the timeout, so the fixed-station read times
    # out.
    assert {:error, :timeout} =
             Bus.transaction(bus_name, Transaction.fprd(0x1002, {0x0010, 2}))
  end

  defp wait_until_bus_ready!(bus_name, attempts_left \\ 10)

  defp wait_until_bus_ready!(_bus_name, 0) do
    flunk("expected raw redundant bus to become ready before delaying the processed return")
  end

  defp wait_until_bus_ready!(bus_name, attempts_left) do
    case Bus.transaction(bus_name, Transaction.brd({0x0000, 1})) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 ->
        wkc

      {:error, :timeout} ->
        Process.sleep(50)
        wait_until_bus_ready!(bus_name, attempts_left - 1)

      other ->
        flunk("expected raw redundant bus warm-up BRD to succeed, got: #{inspect(other)}")
    end
  end
end
