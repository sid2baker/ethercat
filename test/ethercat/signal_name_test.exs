defmodule EtherCAT.SignalNameTest do
  use ExUnit.Case, async: true

  alias EtherCAT.SignalName

  test "builds bounded PDO atom names" do
    assert SignalName.pdo_atom(0x1A00) == :pdo_0x1a00
    assert SignalName.direction_pdo_name(:input, 0x1A00) == "input_pdo_0x1a00"

    assert_raise ArgumentError, fn ->
      SignalName.pdo_atom(0x1_0000)
    end
  end

  test "builds bounded digital channel names" do
    assert SignalName.channel_atom(1) == :ch1

    assert_raise ArgumentError, fn ->
      SignalName.channel_atom(SignalName.max_digital_channels() + 1)
    end
  end
end
