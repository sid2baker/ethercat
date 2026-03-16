defmodule EtherCAT.Integration.Simulator.RedundantPartialProcessedReplyTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.IntegrationSupport.{RedundantSimulatorRing, SimulatorRing}
  alias EtherCAT.Simulator.RawSocket

  setup do
    on_exit(fn ->
      SimulatorRing.stop_all!()
    end)

    :ok
  end

  @tag :raw_socket_redundant
  test "redundant raw bus accepts a degraded processed reply when the redundant copy is late" do
    endpoint = RedundantSimulatorRing.start_simulator!()

    bus_name = :"redundant_partial_processed_reply_#{System.unique_integer([:positive])}"

    {:ok, bus} =
      Bus.start_link(
        name: bus_name,
        interface: endpoint.master_primary_interface,
        backup_interface: endpoint.master_secondary_interface,
        frame_timeout_ms: 10
      )

    on_exit(fn ->
      if Process.alive?(bus) do
        GenServer.stop(bus)
      end
    end)

    baseline_wkc = wait_until_bus_ready!(bus_name)
    assert baseline_wkc > 0

    assert :ok =
             RawSocket.set_response_delay(
               RawSocket.endpoint_name(:primary),
               40,
               :secondary
             )

    assert {:ok, [%{wkc: wkc}]} = Bus.transaction(bus_name, Transaction.brd({0x0000, 1}))
    assert wkc > 0

    assert {:ok,
            %{
              topology: :degraded_primary_leg,
              last_observation: %{
                status: :ok,
                path_shape: :secondary_only,
                primary: %{rx_kind: :none},
                secondary: %{rx_kind: :processed}
              }
            }} = Bus.info(bus_name)
  end

  defp wait_until_bus_ready!(bus_name, attempts_left \\ 10)

  defp wait_until_bus_ready!(_bus_name, 0) do
    flunk("expected raw redundant bus to become ready before enabling delayed redundant copies")
  end

  defp wait_until_bus_ready!(bus_name, attempts_left) do
    case Bus.transaction(bus_name, Transaction.brd({0x0000, 1})) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 ->
        wkc

      {:error, :timeout} ->
        Process.sleep(25)
        wait_until_bus_ready!(bus_name, attempts_left - 1)

      other ->
        flunk("expected raw redundant bus warm-up BRD to succeed, got: #{inspect(other)}")
    end
  end
end
