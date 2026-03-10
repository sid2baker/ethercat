defmodule EtherCATTest do
  use ExUnit.Case, async: false

  setup do
    _ = EtherCAT.stop()
    :ok
  end

  defp ensure_master_running do
    case Process.whereis(EtherCAT.Master) do
      nil -> start_supervised!(EtherCAT.Master)
      pid when is_pid(pid) -> pid
    end
  end

  test "start rejects nil slave placeholders" do
    assert {:error, {:invalid_slave_config, {:nil_entry, 1}}} =
             EtherCAT.start(
               interface: "eth0",
               slaves: [%EtherCAT.Slave.Config{name: :coupler}, nil]
             )

    assert EtherCAT.state() == :idle
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

    assert EtherCAT.state() == :idle
  end

  test "start rejects invalid slave target states" do
    assert {:error, {:invalid_slave_config, {:invalid_options, 0, :invalid_target_state}}} =
             EtherCAT.start(
               interface: "eth0",
               slaves: [
                 [name: :sensor, process_data: :none, target_state: :safeop]
               ]
             )

    assert EtherCAT.state() == :idle
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

  test "await_running returns timeout instead of exiting when the master call itself times out" do
    _pid = ensure_master_running()
    :sys.suspend(EtherCAT.Master)
    on_exit(fn -> :sys.resume(EtherCAT.Master) end)

    assert {:error, :timeout} = EtherCAT.await_running(5)
  end

  test "await_operational returns timeout instead of exiting when the master call itself times out" do
    _pid = ensure_master_running()
    :sys.suspend(EtherCAT.Master)
    on_exit(fn -> :sys.resume(EtherCAT.Master) end)

    assert {:error, :timeout} = EtherCAT.await_operational(5)
  end
end
