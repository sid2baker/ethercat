defmodule EtherCAT.Simulator.Slave.DCTest do
  use ExUnit.Case, async: true

  import EtherCAT.Integration.Assertions
  alias EtherCAT.Simulator.Slave.Definition
  alias EtherCAT.Simulator.Slave.Runtime.Device

  test "dc-capable devices expose progressing system time and latched receive times" do
    slave = Device.new(Definition.build(:mailbox_device, dc_capable?: true), 0)

    before = read_u64(Device.read_register(slave, 0x0910, 8))

    assert_eventually(fn ->
      assert read_u64(Device.read_register(slave, 0x0910, 8)) > before
    end)

    latched = Device.write_register(slave, 0x0900, <<0::32>>)

    assert read_u32(Device.read_register(latched, 0x0900, 4)) <
             read_u32(Device.read_register(latched, 0x0904, 4))

    assert read_u32(Device.read_register(latched, 0x0904, 4)) <
             read_u32(Device.read_register(latched, 0x0908, 4))

    assert read_u32(Device.read_register(latched, 0x0908, 4)) <
             read_u32(Device.read_register(latched, 0x090C, 4))

    assert read_u64(Device.read_register(latched, 0x0918, 8)) > 0
  end

  test "dc writes update offset state without zeroing system time on FRMW-like writes" do
    slave = Device.new(Definition.build(:mailbox_device, dc_capable?: true), 0)

    configured =
      slave
      |> Device.write_register(0x0920, <<123::64-signed-little>>)
      |> Device.write_register(0x0928, <<456::32-little>>)
      |> Device.write_register(0x0930, <<0x2222::16-little>>)

    assert read_i64(Device.read_register(configured, 0x0920, 8)) == 123
    assert read_u32(Device.read_register(configured, 0x0928, 4)) == 456
    assert read_u16(Device.read_register(configured, 0x0930, 2)) == 0x2222
    assert read_u32(Device.read_register(configured, 0x092C, 4)) == 0

    before = read_u64(Device.read_register(configured, 0x0910, 8))
    maintained = Device.write_register(configured, 0x0910, <<0::64>>)

    assert_eventually(fn ->
      after_write = read_u64(Device.read_register(maintained, 0x0910, 8))
      assert after_write > before
      assert after_write > 0
    end)
  end

  defp read_u16(<<value::16-little>>), do: value
  defp read_u32(<<value::32-little>>), do: value
  defp read_u64(<<value::64-little>>), do: value
  defp read_i64(<<value::64-signed-little>>), do: value
end
