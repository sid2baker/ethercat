defmodule EtherCAT.Integration.Simulator.MailboxStepMilestoneAbortTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Driver.EK1100
  alias EtherCAT.IntegrationSupport.Drivers.MailboxDevice
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

  test "mailbox milestones can arm upload aborts after successful segment progress" do
    blob = multi_segment_blob()

    assert {:ok, :preop_ready} = EtherCAT.state()

    assert :ok =
             Simulator.inject_fault(
               Fault.mailbox_abort(:mailbox, 0x2003, 0x01, @abort_code, stage: :upload_segment)
               |> Fault.after_milestone(Fault.mailbox_step(:mailbox, :upload_segment, 2))
             )

    assert {:ok,
            %{
              scheduled_faults: [
                %{
                  fault: {:mailbox_abort, :mailbox, 0x2003, 0x01, @abort_code, :upload_segment},
                  waiting_on: {:mailbox_step, :mailbox, :upload_segment, 2},
                  remaining: 2
                }
              ]
            }} = Simulator.info()

    assert {:error, {:sdo_abort, 0x2003, 0x01, @abort_code}} =
             EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)

    assert {:ok, :preop_ready} = EtherCAT.state()
    assert {:ok, %{scheduled_faults: [], pending_faults: []}} = Simulator.info()

    assert :ok = Simulator.clear_faults()

    assert {:ok, ^blob} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)
    assert {:ok, :preop_ready} = EtherCAT.state()
  end

  test "mailbox milestones can arm download aborts after successful segment progress" do
    original = multi_segment_blob()
    updated = updated_multi_segment_blob()

    assert {:ok, :preop_ready} = EtherCAT.state()
    assert {:ok, ^original} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)

    assert :ok =
             Simulator.inject_fault(
               Fault.mailbox_abort(:mailbox, 0x2003, 0x01, @abort_code, stage: :download_segment)
               |> Fault.after_milestone(Fault.mailbox_step(:mailbox, :download_segment, 2))
             )

    assert {:ok,
            %{
              scheduled_faults: [
                %{
                  fault: {:mailbox_abort, :mailbox, 0x2003, 0x01, @abort_code, :download_segment},
                  waiting_on: {:mailbox_step, :mailbox, :download_segment, 2},
                  remaining: 2
                }
              ]
            }} = Simulator.info()

    assert {:error, {:sdo_abort, 0x2003, 0x01, @abort_code}} =
             EtherCAT.Provisioning.download_sdo(:mailbox, 0x2003, 0x01, updated)

    assert {:ok, ^original} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)
    assert {:ok, :preop_ready} = EtherCAT.state()
    assert {:ok, %{scheduled_faults: [], pending_faults: []}} = Simulator.info()

    assert :ok = Simulator.clear_faults()

    assert :ok = EtherCAT.Provisioning.download_sdo(:mailbox, 0x2003, 0x01, updated)
    assert {:ok, ^updated} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)
    assert {:ok, :preop_ready} = EtherCAT.state()
  end

  defp multi_segment_blob do
    0..191
    |> Enum.to_list()
    |> :erlang.list_to_binary()
  end

  defp updated_multi_segment_blob do
    0..191
    |> Enum.map(fn value -> rem(value * 7 + 3, 256) end)
    |> :erlang.list_to_binary()
  end
end
