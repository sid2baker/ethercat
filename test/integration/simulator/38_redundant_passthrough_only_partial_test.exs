defmodule EtherCAT.Integration.Simulator.RedundantPassthroughOnlyPartialTest do
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
  test "redundant raw bus reports partial when only the passthrough copy arrives before timeout" do
    endpoint = RedundantSimulatorRing.start_simulator!()

    bus_name =
      :"redundant_passthrough_only_partial_#{System.unique_integer([:positive, :monotonic])}"

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
               RawSocket.endpoint_name(:secondary),
               80,
               :primary
             )

    assert {:error, :partial} = Bus.transaction(bus_name, Transaction.brd({0x0000, 1}))

    assert {:ok,
            %{
              last_observation: %{
                status: :partial,
                path_shape: :primary_only,
                primary: %{rx_kind: :passthrough},
                secondary: %{rx_kind: :none}
              }
            }} = Bus.info(bus_name)
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
        Process.sleep(25)
        wait_until_bus_ready!(bus_name, attempts_left - 1)

      other ->
        flunk("expected raw redundant bus warm-up BRD to succeed, got: #{inspect(other)}")
    end
  end
end
