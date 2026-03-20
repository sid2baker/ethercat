defmodule EtherCAT.Integration.Simulator.MalformedDownloadSegmentAckSDOTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Driver.EK1100
  alias EtherCAT.IntegrationSupport.Drivers.MailboxDevice
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault
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

  test "malformed later download acknowledgements surface exact parser errors without mutating the object" do
    original = multi_segment_blob()
    updated = updated_multi_segment_blob()

    assert {:ok, :preop_ready} = EtherCAT.state()
    assert {:ok, ^original} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)

    assert :ok =
             Simulator.inject_fault(
               Fault.mailbox_protocol_fault(
                 :mailbox,
                 0x2003,
                 0x01,
                 :download_segment,
                 :invalid_coe_payload
               )
               |> Fault.after_milestone(Fault.mailbox_step(:mailbox, :download_segment, 1))
             )

    assert {:ok,
            %{
              scheduled_faults: [
                %{
                  fault:
                    {:mailbox_protocol_fault, :mailbox, 0x2003, 0x01, :download_segment,
                     :invalid_coe_payload},
                  waiting_on: {:mailbox_step, :mailbox, :download_segment, 1},
                  remaining: 1
                }
              ]
            }} = Simulator.info()

    assert {:error, :invalid_coe_response} =
             EtherCAT.Provisioning.download_sdo(:mailbox, 0x2003, 0x01, updated)

    assert {:ok, ^original} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)
    assert {:ok, :preop_ready} = EtherCAT.state()
    assert {:ok, %{scheduled_faults: [], pending_faults: []}} = Simulator.info()

    assert :ok = Simulator.clear_faults()

    assert :ok = EtherCAT.Provisioning.download_sdo(:mailbox, 0x2003, 0x01, updated)
    assert {:ok, ^updated} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)
    assert {:ok, :preop_ready} = EtherCAT.state()
  end

  test "malformed final download acknowledgements still reflect the committed object" do
    original = multi_segment_blob()
    updated = updated_multi_segment_blob()

    assert {:ok, :preop_ready} = EtherCAT.state()
    assert {:ok, ^original} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)

    assert :ok =
             Simulator.inject_fault(
               Fault.mailbox_protocol_fault(
                 :mailbox,
                 0x2003,
                 0x01,
                 :download_segment,
                 {:segment_command, 0x60}
               )
               |> Fault.after_milestone(Fault.mailbox_step(:mailbox, :download_segment, 2))
             )

    assert {:error, {:unexpected_sdo_segment_command, 0x60}} =
             EtherCAT.Provisioning.download_sdo(:mailbox, 0x2003, 0x01, updated)

    assert {:ok, ^updated} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)
    assert {:ok, :preop_ready} = EtherCAT.state()
    assert {:ok, %{scheduled_faults: [], pending_faults: []}} = Simulator.info()

    assert :ok = Simulator.clear_faults()

    assert :ok = EtherCAT.Provisioning.download_sdo(:mailbox, 0x2003, 0x01, original)
    assert {:ok, ^original} = EtherCAT.Provisioning.upload_sdo(:mailbox, 0x2003, 0x01)
    assert {:ok, :preop_ready} = EtherCAT.state()
  end

  defp multi_segment_blob do
    0..191
    |> Enum.to_list()
    |> :erlang.list_to_binary()
  end

  defp updated_multi_segment_blob do
    0..191
    |> Enum.map(fn value -> rem(value * 11 + 5, 256) end)
    |> :erlang.list_to_binary()
  end
end
