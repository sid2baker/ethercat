defmodule EtherCAT.IntegrationSupport.SimulatorRingTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Driver.EK1100
  alias EtherCAT.IntegrationSupport.{Hardware, SimulatorRing}
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Simulator.Transport.Udp
  alias EtherCAT.Slave.ESC.Registers

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)
    :ok
  end

  test "the shared transport budget tolerates a delayed simulator reply" do
    boot_preop!()

    assert {:ok, %{frame_timeout_ms: timeout_ms}} = Bus.info()
    assert timeout_ms == SimulatorRing.frame_timeout_ms()

    # Reproduce a host pause longer than the old 100ms fixture budget without
    # changing the response, masking a transport error, or retrying the request.
    :ok = :sys.suspend(Udp)

    resume =
      Task.async(fn ->
        Process.sleep(200)
        :sys.resume(Udp)
      end)

    try do
      assert {:ok, [%{wkc: 1}]} = Bus.transaction(Transaction.brd(Registers.al_status()))
      assert {:ok, %{timeout_count: 0}} = Bus.info()
      assert :ok = Task.await(resume)
    after
      :sys.resume(Udp)
      Task.shutdown(resume)
    end
  end

  test "scenarios can still override the shared transport budget explicitly" do
    boot_preop!(frame_timeout_ms: 750)
    assert {:ok, %{frame_timeout_ms: 750}} = Bus.info()
  end

  test "segmented fixtures share health timing but retain per-slave overrides" do
    defaults = SimulatorRing.slave_configs(:segmented)

    assert Enum.find(defaults, &(&1.name == :outputs)).health_poll_ms ==
             SimulatorRing.health_poll_ms()

    assert Enum.find(defaults, &(&1.name == :mailbox)).health_poll_ms ==
             SimulatorRing.health_poll_ms()

    overrides =
      SimulatorRing.slave_configs(:segmented,
        output_health_poll_ms: 250,
        mailbox_health_poll_ms: 300
      )

    assert Enum.find(overrides, &(&1.name == :outputs)).health_poll_ms == 250
    assert Enum.find(overrides, &(&1.name == :mailbox)).health_poll_ms == 300
  end

  defp boot_preop!(start_opts \\ []) do
    SimulatorRing.boot_preop_ready!(
      simulator_opts: [devices: [Slave.from_driver(EK1100, name: :coupler)], connections: []],
      start_opts:
        Keyword.merge(
          [domains: [], slaves: [Hardware.coupler(target_state: :preop)]],
          start_opts
        )
    )
  end
end
