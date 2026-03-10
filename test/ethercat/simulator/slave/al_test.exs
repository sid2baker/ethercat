defmodule EtherCAT.Simulator.Slave.ALTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Simulator.Slave.Runtime.AL
  alias EtherCAT.Simulator.Slave.Runtime.Device

  test "apply_control enforces AL transition discipline and updates AL status" do
    slave = Device.new(Slave.digital_io(), 0)

    assert {:error, invalid} = AL.apply_control(slave, 0x08)
    assert invalid.state == :init
    assert invalid.al_error?
    assert invalid.al_status_code == 0x0011
    assert Device.read_register(invalid, 0x0130, 2) == <<0x11, 0x00>>
    assert Device.read_register(invalid, 0x0134, 2) == <<0x11, 0x00>>

    assert {:ok, preop} = AL.apply_control(slave, 0x02)
    assert {:ok, safeop} = AL.apply_control(preop, 0x04)
    assert {:ok, op} = AL.apply_control(safeop, 0x08)

    assert preop.state == :preop
    assert safeop.state == :safeop
    assert op.state == :op
    refute op.al_error?
    assert op.al_status_code == 0
    assert Device.read_register(op, 0x0130, 2) == <<0x08, 0x00>>
    assert Device.read_register(op, 0x0134, 2) == <<0x00, 0x00>>
  end
end
