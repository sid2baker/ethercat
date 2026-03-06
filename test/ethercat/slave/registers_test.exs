defmodule EtherCAT.Slave.RegistersTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Slave.Registers

  test "dc activation values are encoded as one byte" do
    assert Registers.dc_activation() == {0x0981, 1}
    assert Registers.dc_activation(0x03) == {0x0981, <<0x03>>}
    assert Registers.dc_activation(0x07) == {0x0981, <<0x07>>}
  end

  test "dc cyclic unit control uses 0x0980" do
    assert Registers.dc_cyclic_unit_control() == {0x0980, 2}
    assert Registers.dc_cyclic_unit_control(0x0000) == {0x0980, <<0::16-little>>}
  end

  test "sync1 cycle register uses 0x09A4" do
    assert Registers.dc_sync1_cycle_time() == {0x09A4, 4}
    assert Registers.dc_sync1_cycle_time(250_000) == {0x09A4, <<250_000::32-little>>}
  end

  test "latch control registers are writable" do
    assert Registers.dc_latch0_control() == {0x09A8, 1}
    assert Registers.dc_latch0_control(0x03) == {0x09A8, <<0x03>>}
    assert Registers.dc_latch1_control() == {0x09A9, 1}
    assert Registers.dc_latch1_control(0x02) == {0x09A9, <<0x02>>}
  end

  test "latch status and timestamps map to ESC dc register range" do
    assert Registers.dc_latch_event_status() == {0x09AE, 2}
    assert Registers.dc_latch0_status() == {0x09AE, 1}
    assert Registers.dc_latch1_status() == {0x09AF, 1}

    assert Registers.dc_latch0_pos_time() == {0x09B0, 8}
    assert Registers.dc_latch0_neg_time() == {0x09B8, 8}
    assert Registers.dc_latch1_pos_time() == {0x09C0, 8}
    assert Registers.dc_latch1_neg_time() == {0x09C8, 8}
  end
end
