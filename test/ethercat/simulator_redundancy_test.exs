defmodule EtherCAT.SimulatorRedundancyTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Bus.Datagram
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator

  setup do
    on_exit(fn ->
      SimulatorRing.stop_all!()
    end)

    SimulatorRing.boot_operational!()
    :ok
  end

  test "info reports simulator topology changes" do
    assert {:ok, %{topology: %{mode: :linear}}} = Simulator.info()

    assert :ok = Simulator.set_topology(:redundant)
    assert {:ok, %{topology: %{mode: :redundant, break_after: nil}}} = Simulator.info()

    assert :ok = Simulator.set_topology({:redundant, break_after: 2})
    assert {:ok, %{topology: %{mode: :redundant, break_after: 2}}} = Simulator.info()
  end

  test "healthy redundant secondary ingress is a passthrough copy" do
    assert :ok = Simulator.set_topology(:redundant)

    datagram = station_read_datagram(0x1002)

    assert {:ok, [%{data: <<0x00, 0x00>>, wkc: 0}]} =
             Simulator.process_datagrams([datagram], ingress: :secondary)

    assert {:ok, [%{data: <<0x02, 0x10>>, wkc: 1}]} =
             Simulator.process_datagrams([datagram], ingress: :primary)
  end

  test "single break makes right-side station traffic reachable only from secondary ingress" do
    assert :ok = Simulator.set_topology({:redundant, break_after: 2})

    datagram = station_read_datagram(0x1002)

    assert {:ok, [%{data: <<0x00, 0x00>>, wkc: 0}]} =
             Simulator.process_datagrams([datagram], ingress: :primary)

    assert {:ok, [%{data: <<0x02, 0x10>>, wkc: 1}]} =
             Simulator.process_datagrams([datagram], ingress: :secondary)
  end

  defp station_read_datagram(station) do
    %Datagram{
      cmd: 4,
      idx: 1,
      address: <<station::little-unsigned-16, 0x0010::little-unsigned-16>>,
      data: <<0x00, 0x00>>
    }
  end
end
