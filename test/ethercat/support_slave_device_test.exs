defmodule EtherCAT.SupportSlaveDeviceTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Support.Slave.Device
  alias EtherCAT.Support.Slave.Fixture

  test "AL control enforces basic transition discipline" do
    slave = Device.new(Fixture.digital_io(), 0)

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
    slave = Device.new(Fixture.lan9252_demo(), 0)

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

    assert slave.object_dictionary[{0x2000, 0x01}] == <<0x78, 0x56>>
  end

  defp pad_mailbox(frame, size) do
    frame <> :binary.copy(<<0>>, size - byte_size(frame))
  end
end
