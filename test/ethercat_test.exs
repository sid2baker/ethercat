defmodule EtherCATTest do
  use ExUnit.Case, async: false

  setup do
    _ = EtherCAT.stop()
    :ok
  end

  test "start rejects nil slave placeholders" do
    assert {:error, {:invalid_slave_config, {:nil_entry, 1}}} =
             EtherCAT.start(
               interface: "eth0",
               slaves: [%EtherCAT.Slave.Config{name: :coupler}, nil]
             )

    assert EtherCAT.state() == :idle
  end

  test "slave config defaults to the built-in default driver" do
    cfg = %EtherCAT.Slave.Config{name: :coupler}
    assert cfg.driver == EtherCAT.Slave.Driver.Default
  end

  test "default slave driver is a safe no-op profile" do
    driver = EtherCAT.Slave.Driver.Default

    assert driver.process_data_profile(%{}) == %{}
    assert driver.encode_outputs(:unused, %{}, 1) == <<>>
    assert driver.decode_inputs(:unused, %{}, <<0xAB, 0xCD>>) == <<0xAB, 0xCD>>
  end
end
