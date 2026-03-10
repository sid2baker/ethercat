defmodule EtherCAT.Simulator.Slave.ProcessImageTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Simulator.Slave.Runtime.Device
  alias EtherCAT.Simulator.Slave.Runtime.ProcessImage

  test "set_value updates output bytes and mirrored inputs" do
    slave = Device.new(Slave.digital_io(), 0)

    assert {:ok, slave} = ProcessImage.set_value(slave, :out, 3)
    assert ProcessImage.output_image(slave) == <<3>>
    assert {:ok, 3} = ProcessImage.get_value(slave, :out)
    assert {:ok, 3} = ProcessImage.get_value(slave, :in)
  end

  test "set_value stores input overrides and refreshes readable values" do
    slave = Device.new(Slave.lan9252_demo(), 0)

    assert {:ok, slave} = ProcessImage.set_value(slave, :button1, 7)
    assert {:ok, 7} = ProcessImage.get_value(slave, :button1)
  end
end
