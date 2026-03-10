defmodule EtherCAT.SimulatorSlaveDeviceTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Simulator.Slave.Runtime.Device
  alias EtherCAT.Simulator.Slave.Object

  test "AL control enforces basic transition discipline" do
    slave = Device.new(Slave.digital_io(), 0)

    invalid = Device.write_register(slave, 0x0120, <<0x08, 0x00>>)

    assert invalid.state == :init
    assert invalid.al_error?
    assert invalid.al_status_code == 0x0011
    assert Device.read_register(invalid, 0x0130, 2) == <<0x11, 0x00>>
    assert Device.read_register(invalid, 0x0134, 2) == <<0x11, 0x00>>

    preop = Device.write_register(invalid, 0x0120, <<0x02, 0x00>>)
    safeop = Device.write_register(preop, 0x0120, <<0x04, 0x00>>)
    op = Device.write_register(safeop, 0x0120, <<0x08, 0x00>>)

    assert preop.state == :preop
    refute preop.al_error?
    assert preop.al_status_code == 0

    assert safeop.state == :safeop
    refute safeop.al_error?
    assert safeop.al_status_code == 0

    assert op.state == :op
    refute op.al_error?
    assert op.al_status_code == 0
    assert Device.read_register(op, 0x0130, 2) == <<0x08, 0x00>>
    assert Device.read_register(op, 0x0134, 2) == <<0x00, 0x00>>
  end

  test "mailbox expedited upload and download update the simulated object dictionary" do
    slave = Device.new(Slave.lan9252_demo(), 0)

    upload_request =
      <<10::16-little, 0::16-little, 0::8, 0x13::8, 0x2000::16-little, 0x40, 0x00, 0x20, 0x01,
        0::32-little>>
      |> pad_mailbox(slave.mailbox_config.recv_size)

    slave = Device.write_datagram(slave, slave.mailbox_config.recv_offset, upload_request)
    assert Device.read_register(slave, 0x080D, 1) == <<0x08>>

    {slave, response} =
      Device.read_datagram(
        slave,
        slave.mailbox_config.send_offset,
        slave.mailbox_config.send_size
      )

    assert <<10::16-little, _::16, _::8, 0x13::8, 0x3000::16-little, 0x4B, 0x00, 0x20, 0x01, 0x34,
             0x12, 0x00, 0x00, _::binary>> = response

    assert Device.read_register(slave, 0x080D, 1) == <<0x00>>

    download_request =
      <<10::16-little, 0::16-little, 0::8, 0x23::8, 0x2000::16-little, 0x2B, 0x00, 0x20, 0x01,
        0x78, 0x56, 0x00, 0x00>>
      |> pad_mailbox(slave.mailbox_config.recv_size)

    slave = Device.write_datagram(slave, slave.mailbox_config.recv_offset, download_request)

    {slave, ack} =
      Device.read_datagram(
        slave,
        slave.mailbox_config.send_offset,
        slave.mailbox_config.send_size
      )

    assert <<10::16-little, _::16, _::8, 0x23::8, 0x3000::16-little, 0x60, 0x00, 0x20, 0x01,
             0::32-little, _::binary>> = ack

    assert %Object{} = entry = slave.objects[{0x2000, 0x01}]
    assert 0x5678 == Object.get_value(entry)
  end

  test "fault helpers can latch AL errors, retreat to SAFEOP, and inject mailbox aborts" do
    slave = Device.new(Slave.lan9252_demo(), 0)

    errored = Device.latch_al_error(slave, 0x001D)
    assert errored.al_error?
    assert errored.al_status_code == 0x001D
    assert Device.read_register(errored, 0x0130, 2) == <<0x11, 0x00>>
    assert Device.read_register(errored, 0x0134, 2) == <<0x1D, 0x00>>

    safeop = Device.retreat_to_safeop(errored)
    assert safeop.state == :safeop
    refute safeop.al_error?
    assert safeop.al_status_code == 0
    assert Device.read_register(safeop, 0x0130, 2) == <<0x04, 0x00>>

    aborting = Device.inject_mailbox_abort(safeop, 0x2000, 0x01, 0x0601_0002)

    upload_request =
      <<10::16-little, 0::16-little, 0::8, 0x13::8, 0x2000::16-little, 0x40, 0x00, 0x20, 0x01,
        0::32-little>>
      |> pad_mailbox(aborting.mailbox_config.recv_size)

    aborting =
      Device.write_datagram(aborting, aborting.mailbox_config.recv_offset, upload_request)

    {_aborting, abort_reply} =
      Device.read_datagram(
        aborting,
        aborting.mailbox_config.send_offset,
        aborting.mailbox_config.send_size
      )

    assert <<10::16-little, _::16, _::8, 0x13::8, 0x3000::16-little, 0x80, 0x00, 0x20, 0x01, 0x02,
             0x00, 0x01, 0x06, _::binary>> = abort_reply

    cleared = Device.clear_faults(aborting)
    refute cleared.al_error?
    assert cleared.al_status_code == 0
    assert cleared.mailbox_abort_codes == %{}
  end

  test "signal access can get and set named input and output values" do
    slave = Device.new(Slave.lan9252_demo(), 0)

    assert {:ok, 0} = Device.get_value(slave, :led0)
    assert {:ok, 0} = Device.get_value(slave, :button1)
    assert {:error, :unknown_signal} = Device.get_value(slave, :missing)

    assert {:ok, slave} = Device.set_value(slave, :button1, 7)
    assert {:ok, 7} = Device.get_value(slave, :button1)

    assert {:ok, slave} = Device.set_value(slave, :led0, true)
    assert {:ok, slave} = Device.set_value(slave, :led1, 2)
    assert {:ok, 1} = Device.get_value(slave, :led0)
    assert {:ok, 2} = Device.get_value(slave, :led1)

    assert Device.output_image(slave) == <<1, 2>>
  end

  defp pad_mailbox(frame, size) do
    frame <> :binary.copy(<<0>>, size - byte_size(frame))
  end
end
