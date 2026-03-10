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
end
