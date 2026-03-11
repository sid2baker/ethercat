defmodule EtherCAT.Integration.Simulator.MailboxProtocolFaultSDOTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.Drivers.{EK1100, MailboxDevice}
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    devices = [
      Slave.from_driver(EK1100, name: :coupler),
      Slave.from_driver(MailboxDevice, name: :mailbox)
    ]

    slaves = [
      %SlaveConfig{
        name: :coupler,
        driver: EK1100,
        process_data: :none,
        target_state: :preop
      },
      %SlaveConfig{
        name: :mailbox,
        driver: MailboxDevice,
        process_data: :none,
        target_state: :preop
      }
    ]

    SimulatorRing.boot_preop_ready!(
      simulator_opts: [devices: devices, connections: []],
      start_opts: [domains: [], slaves: slaves, frame_timeout_ms: 20],
      await_running_ms: 2_500
    )

    :ok
  end

  test "init-phase mailbox counter mismatches surface as exact CoE errors" do
    value = "hello-sim\0\0\0"

    assert :preop_ready = EtherCAT.state()

    assert :ok =
             Simulator.inject_fault(
               {:mailbox_protocol_fault, :mailbox, 0x2001, 0x01, :upload_init, :counter_mismatch}
             )

    assert {:error, {:unexpected_mailbox_counter, 1, 2}} =
             EtherCAT.upload_sdo(:mailbox, 0x2001, 0x01)

    assert :preop_ready = EtherCAT.state()

    assert :ok = Simulator.clear_faults()

    assert {:ok, ^value} = EtherCAT.upload_sdo(:mailbox, 0x2001, 0x01)
    assert :preop_ready = EtherCAT.state()
  end

  test "segmented mailbox toggle mismatches surface as exact CoE errors" do
    blob = multi_segment_blob()

    assert :preop_ready = EtherCAT.state()

    assert :ok =
             Simulator.inject_fault(
               {:mailbox_protocol_fault, :mailbox, 0x2003, 0x01, :upload_segment,
                :toggle_mismatch}
             )

    assert {:error, {:toggle_mismatch, 0, 1}} =
             EtherCAT.upload_sdo(:mailbox, 0x2003, 0x01)

    assert :preop_ready = EtherCAT.state()

    assert :ok = Simulator.clear_faults()

    assert {:ok, ^blob} = EtherCAT.upload_sdo(:mailbox, 0x2003, 0x01)
    assert :preop_ready = EtherCAT.state()
  end

  defp multi_segment_blob do
    0..191
    |> Enum.to_list()
    |> :erlang.list_to_binary()
  end
end
