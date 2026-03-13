defmodule EtherCAT.Integration.Simulator.SegmentedMailboxAbortSDOTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.Drivers.{EK1100, MailboxDevice}
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @abort_code 0x0800_0000

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

  test "public segmented sdo upload can abort mid-transfer without degrading the master" do
    blob = segmented_blob()

    assert {:ok, :preop_ready} = EtherCAT.state()
    assert {:ok, ^blob} = EtherCAT.upload_sdo(:mailbox, 0x2002, 0x01)

    assert :ok =
             Simulator.inject_fault(
               Fault.mailbox_abort(:mailbox, 0x2002, 0x01, @abort_code, stage: :upload_segment)
             )

    assert {:error, {:sdo_abort, 0x2002, 0x01, @abort_code}} =
             EtherCAT.upload_sdo(:mailbox, 0x2002, 0x01)

    assert {:ok, :preop_ready} = EtherCAT.state()

    assert :ok = Simulator.clear_faults()

    assert {:ok, ^blob} = EtherCAT.upload_sdo(:mailbox, 0x2002, 0x01)
    assert {:ok, :preop_ready} = EtherCAT.state()
  end

  test "public segmented sdo download can abort mid-transfer without mutating the object" do
    original = segmented_blob()
    updated = updated_segmented_blob()

    assert {:ok, :preop_ready} = EtherCAT.state()
    assert {:ok, ^original} = EtherCAT.upload_sdo(:mailbox, 0x2002, 0x01)

    assert :ok =
             Simulator.inject_fault(
               Fault.mailbox_abort(:mailbox, 0x2002, 0x01, @abort_code, stage: :download_segment)
             )

    assert {:error, {:sdo_abort, 0x2002, 0x01, @abort_code}} =
             EtherCAT.download_sdo(:mailbox, 0x2002, 0x01, updated)

    assert {:ok, ^original} = EtherCAT.upload_sdo(:mailbox, 0x2002, 0x01)
    assert {:ok, :preop_ready} = EtherCAT.state()

    assert :ok = Simulator.clear_faults()

    assert :ok = EtherCAT.download_sdo(:mailbox, 0x2002, 0x01, updated)
    assert {:ok, ^updated} = EtherCAT.upload_sdo(:mailbox, 0x2002, 0x01)
    assert {:ok, :preop_ready} = EtherCAT.state()
  end

  defp segmented_blob do
    0..79
    |> Enum.to_list()
    |> :erlang.list_to_binary()
  end

  defp updated_segmented_blob do
    0..79
    |> Enum.map(fn value -> rem(value * 3, 256) end)
    |> :erlang.list_to_binary()
  end
end
