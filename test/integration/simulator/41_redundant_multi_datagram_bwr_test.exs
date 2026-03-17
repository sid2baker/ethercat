defmodule EtherCAT.Integration.Simulator.RedundantMultiDatagramBwrTest do
  @moduledoc """
  Reproduces a hardware bug where multi-datagram BWR transactions (e.g.
  init_default_reset with 13 register writes) return all wkc=0 in redundant
  mode, even though single-datagram BRD works fine.

  Root cause: AF_PACKET outgoing echoes (kernel loopback copies of TX frames)
  arrive faster than real cross-delivery responses. Echoes have wkc=0 and may
  carry a source MAC that doesn't match either NIC, causing `:unknown`
  classification. If two echoes complete the exchange before the real processed
  response arrives, the caller sees all-zero wkc values.
  """
  use ExUnit.Case, async: false

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Master.Startup.Reset, as: InitReset
  alias EtherCAT.IntegrationSupport.{RedundantSimulatorRing, SimulatorRing}

  setup do
    on_exit(fn ->
      SimulatorRing.stop_all!()
    end)

    :ok
  end

  @tag :raw_socket_redundant
  test "redundant bus handles multi-datagram BWR (init_default_reset) with wkc > 0" do
    endpoint = RedundantSimulatorRing.start_simulator!()

    bus_name = :"redundant_bwr_test_#{System.unique_integer([:positive])}"

    {:ok, bus} =
      Bus.start_link(
        name: bus_name,
        interface: endpoint.master_primary_interface,
        backup_interface: endpoint.master_secondary_interface,
        frame_timeout_ms: 100
      )

    on_exit(fn ->
      if Process.alive?(bus), do: GenServer.stop(bus)
    end)

    # Warm up: single-datagram BRD must work first
    baseline_wkc = wait_until_bus_ready!(bus_name)
    assert baseline_wkc > 0, "baseline BRD must succeed before testing BWR"

    # The actual bug: multi-datagram BWR (13 datagrams, same as init_default_reset)
    tx = InitReset.transaction()

    assert {:ok, results} = Bus.transaction(bus_name, tx)

    wkcs = Enum.map(results, & &1.wkc)

    # Each BWR should be processed by all slaves in the simulator ring (3 slaves).
    # Some registers are optional (DC-related) and may return wkc=0 on slaves
    # that don't support them, but the required ones must have wkc > 0.
    required_wkcs = Enum.take(wkcs, 5) ++ Enum.slice(wkcs, 9, 4)

    assert Enum.all?(required_wkcs, &(&1 > 0)),
           "expected required BWR datagrams to have wkc > 0, got wkcs: #{inspect(wkcs)}"
  end

  @tag :raw_socket_redundant
  test "redundant bus handles multi-datagram BWR consistently across repeated transactions" do
    endpoint = RedundantSimulatorRing.start_simulator!()

    bus_name = :"redundant_bwr_repeat_#{System.unique_integer([:positive])}"

    {:ok, bus} =
      Bus.start_link(
        name: bus_name,
        interface: endpoint.master_primary_interface,
        backup_interface: endpoint.master_secondary_interface,
        frame_timeout_ms: 100
      )

    on_exit(fn ->
      if Process.alive?(bus), do: GenServer.stop(bus)
    end)

    wait_until_bus_ready!(bus_name)

    # Build a simpler multi-datagram BWR (5 register writes) to isolate the
    # echo race from init_default_reset's optional DC registers.
    tx =
      Transaction.new()
      |> Transaction.bwr({0x0120, <<0x04, 0x00>>})
      |> Transaction.bwr({0x0200, <<0x04, 0x00>>})
      |> Transaction.bwr({0x0300, <<0::64>>})
      |> Transaction.bwr({0x0310, <<0x01>>})
      |> Transaction.bwr({0x0120, <<0x04, 0x00>>})

    # Run the transaction multiple times — echo race is timing-dependent,
    # so repetition increases confidence.
    failures =
      for i <- 1..10, reduce: [] do
        acc ->
          case Bus.transaction(bus_name, tx) do
            {:ok, results} ->
              wkcs = Enum.map(results, & &1.wkc)

              if Enum.all?(wkcs, &(&1 > 0)) do
                acc
              else
                [{i, wkcs} | acc]
              end

            {:error, reason} ->
              [{i, {:error, reason}} | acc]
          end
      end

    assert failures == [],
           "expected all 10 BWR transactions to succeed, failures: #{inspect(Enum.reverse(failures))}"
  end

  @tag :raw_socket_redundant
  test "redundant BWR succeeds even with echo filtering disabled (link-layer defense)" do
    # Disables transport-level echo filtering (drop_outgoing_echo?: false) to
    # exercise the link-layer wkc=0 guard. On veth pairs, outgoing echoes have
    # pkttype: :outgoing; without the filter, they reach the link as :unknown
    # frames with wkc=0 — reproducing the real hardware scenario.
    endpoint = RedundantSimulatorRing.start_simulator!()

    bus_name = :"redundant_bwr_no_echo_filter_#{System.unique_integer([:positive])}"

    {:ok, bus} =
      Bus.start_link(
        name: bus_name,
        interface: endpoint.master_primary_interface,
        backup_interface: endpoint.master_secondary_interface,
        frame_timeout_ms: 100,
        drop_outgoing_echo?: false
      )

    on_exit(fn ->
      if Process.alive?(bus), do: GenServer.stop(bus)
    end)

    wait_until_bus_ready!(bus_name)

    tx = InitReset.transaction()

    failures =
      for i <- 1..5, reduce: [] do
        acc ->
          case Bus.transaction(bus_name, tx) do
            {:ok, results} ->
              # Check required BWR datagrams (skip optional DC ones at indices 5-8)
              required_wkcs = Enum.take(Enum.map(results, & &1.wkc), 5)

              if Enum.all?(required_wkcs, &(&1 > 0)) do
                acc
              else
                [{i, Enum.map(results, & &1.wkc)} | acc]
              end

            {:error, reason} ->
              [{i, {:error, reason}} | acc]
          end
      end

    assert failures == [],
           "expected BWR to succeed without echo filtering, failures: #{inspect(Enum.reverse(failures))}"
  end

  @tag :raw_socket_redundant
  test "single-datagram BRD works in redundant mode (baseline sanity check)" do
    endpoint = RedundantSimulatorRing.start_simulator!()

    bus_name = :"redundant_brd_baseline_#{System.unique_integer([:positive])}"

    {:ok, bus} =
      Bus.start_link(
        name: bus_name,
        interface: endpoint.master_primary_interface,
        backup_interface: endpoint.master_secondary_interface,
        frame_timeout_ms: 100
      )

    on_exit(fn ->
      if Process.alive?(bus), do: GenServer.stop(bus)
    end)

    wait_until_bus_ready!(bus_name)

    assert {:ok, [%{wkc: wkc}]} = Bus.transaction(bus_name, Transaction.brd({0x0000, 1}))
    assert wkc > 0
  end

  defp wait_until_bus_ready!(bus_name, attempts_left \\ 20)

  defp wait_until_bus_ready!(_bus_name, 0) do
    flunk("redundant bus did not become ready after 20 attempts")
  end

  defp wait_until_bus_ready!(bus_name, attempts_left) do
    case Bus.transaction(bus_name, Transaction.brd({0x0000, 1})) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 ->
        wkc

      {:error, :timeout} ->
        Process.sleep(50)
        wait_until_bus_ready!(bus_name, attempts_left - 1)

      {:ok, [%{wkc: 0}]} ->
        Process.sleep(50)
        wait_until_bus_ready!(bus_name, attempts_left - 1)

      other ->
        flunk("expected BRD warmup to succeed, got: #{inspect(other)}")
    end
  end
end
