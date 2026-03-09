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

    assert EtherCAT.phase() == :idle
  end

  test "start rejects invalid process_data requests" do
    assert {:error, {:invalid_slave_config, {:invalid_options, 0, :invalid_process_data}}} =
             EtherCAT.start(
               interface: "eth0",
               slaves: [
                 %EtherCAT.Slave.Config{
                   name: :sensor,
                   process_data: [{:ch1, "main"}]
                 }
               ]
             )

    assert EtherCAT.phase() == :idle
  end

  test "start rejects invalid slave target states" do
    assert {:error, {:invalid_slave_config, {:invalid_options, 0, :invalid_target_state}}} =
             EtherCAT.start(
               interface: "eth0",
               slaves: [
                 [name: :sensor, process_data: :none, target_state: :safeop]
               ]
             )

    assert EtherCAT.phase() == :idle
  end

  test "slave config defaults to the built-in default driver" do
    cfg = %EtherCAT.Slave.Config{name: :coupler}
    assert cfg.driver == EtherCAT.Slave.Driver.Default
    assert cfg.process_data == :none
    assert cfg.target_state == :op
    assert cfg.sync == nil
  end

  test "default slave driver is a safe no-op profile" do
    driver = EtherCAT.Slave.Driver.Default

    assert driver.process_data_model(%{}) == []
    assert driver.encode_signal(:unused, %{}, 1) == <<>>
    assert driver.decode_signal(:unused, %{}, <<0xAB, 0xCD>>) == <<0xAB, 0xCD>>
  end

  test "dc_status reports either idle-disabled or not_started without an active session" do
    status = EtherCAT.dc_status()

    assert match?({:error, :not_started}, status) or
             match?(%EtherCAT.DC.Status{lock_state: :disabled}, status)
  end
end
