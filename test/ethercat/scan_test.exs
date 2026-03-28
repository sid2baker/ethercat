defmodule EtherCAT.ScanTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Scan
  alias EtherCAT.Simulator

  @master_ip {127, 0, 0, 1}
  @simulator_ip {127, 0, 0, 2}

  setup do
    _ = Simulator.stop()

    on_exit(fn ->
      _ = Simulator.stop()
    end)

    :ok
  end

  test "scan/1 reports observed topology without starting the master" do
    assert {:ok, _supervisor} =
             Simulator.start(
               devices: SimulatorRing.devices(),
               backend: {:udp, %{host: @simulator_ip, port: 0}}
             )

    assert {:ok, %EtherCAT.Simulator.Status{backend: %EtherCAT.Backend.Udp{port: port}}} =
             Simulator.status()

    assert {:ok, %EtherCAT.Scan.Result{} = result} =
             Scan.scan({:udp, %{host: @simulator_ip, bind_ip: @master_ip, port: port}})

    assert %EtherCAT.Backend.Udp{host: @simulator_ip, bind_ip: @master_ip, port: ^port} =
             result.backend

    assert result.topology == %{slave_count: 3, stations: [0x1000, 0x1001, 0x1002]}
    assert length(result.discovered_slaves) == 3
    assert [] == result.observed_faults

    assert [
             %{
               position: 0,
               station: 0x1000,
               identity: %{product_code: 0x044C_2C52},
               al_state: :init
             },
             %{
               position: 1,
               station: 0x1001,
               identity: %{product_code: 0x0711_3052},
               al_state: :init
             },
             %{
               position: 2,
               station: 0x1002,
               identity: %{product_code: 0x0AF9_3052},
               al_state: :init
             }
           ] = result.discovered_slaves
  end
end
