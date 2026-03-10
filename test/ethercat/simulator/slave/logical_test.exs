defmodule EtherCAT.Simulator.Slave.LogicalTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Slave.ESC.Registers
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Simulator.Slave.Runtime.Device
  alias EtherCAT.Simulator.Slave.Runtime.Logical

  test "active_fmmus/1 parses configured FMMUs from ESC memory" do
    slave =
      Slave.digital_io()
      |> Device.new(0)
      |> configure_fmmu(0, 0x1000, 1, 0x1100, 0x02)
      |> configure_fmmu(1, 0x1001, 1, 0x1180, 0x01)

    assert [
             %{index: 0, logical_start: 0x1000, length: 1, phys_start: 0x1100, type: 0x02},
             %{index: 1, logical_start: 0x1001, length: 1, phys_start: 0x1180, type: 0x01}
           ] = Logical.active_fmmus(slave)
  end

  test "LRW updates outputs, reads inputs, and accumulates correct WKC" do
    {:ok, slave} =
      Slave.lan9252_demo()
      |> Device.new(0)
      |> Device.set_value(:button1, 7)

    slave =
      slave
      |> configure_fmmu(0, 0x1000, 2, 0x1100, 0x02)
      |> configure_fmmu(1, 0x1002, 1, 0x1180, 0x01)

    {updated_slave, response, wkc} = Logical.read_write(slave, 12, 0x1000, <<1, 2, 0>>)

    assert Device.output_image(updated_slave) == <<1, 2>>
    assert response == <<1, 2, 7>>
    assert wkc == 3
  end

  defp configure_fmmu(slave, index, logical_start, length, phys_start, type) do
    base = Registers.fmmu(index)

    entry =
      <<logical_start::32-little, length::16-little, 0::8, 7::8, phys_start::16-little, 0::8,
        type::8, 0x01::8, 0::24>>

    Device.write_register(slave, base, entry)
  end
end
