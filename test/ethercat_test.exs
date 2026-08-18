defmodule EtherCATTest do
  use ExUnit.Case, async: false

  setup do
    stop_current_session()
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
               backend: raw_backend("eth0"),
               slaves: [%EtherCAT.Slave.Config{name: :coupler}, nil]
             )

    assert {:error, :not_started} = EtherCAT.Session.current()
  end

  test "start rejects invalid process_data requests" do
    assert {:error, {:invalid_slave_config, {:invalid_options, 0, :invalid_process_data}}} =
             EtherCAT.start(
               backend: raw_backend("eth0"),
               slaves: [
                 %EtherCAT.Slave.Config{
                   name: :sensor,
                   process_data: [{:ch1, "main"}]
                 }
               ]
             )

    assert {:error, :not_started} = EtherCAT.Session.current()
  end

  test "start rejects invalid slave target states" do
    assert {:error, {:invalid_slave_config, {:invalid_options, 0, :invalid_target_state}}} =
             EtherCAT.start(
               backend: raw_backend("eth0"),
               slaves: [
                 [name: :sensor, process_data: :none, target_state: :safeop]
               ]
             )

    assert {:error, :not_started} = EtherCAT.Session.current()
  end

  test "slave config defaults to the built-in default driver" do
    cfg = %EtherCAT.Slave.Config{name: :coupler}
    assert cfg.driver == EtherCAT.Driver.Default
    assert cfg.process_data == :none
    assert cfg.target_state == :op
    assert cfg.sync == nil
  end

  test "default slave driver is a safe no-op profile" do
    driver = EtherCAT.Driver.Default

    assert driver.signal_model(%{}) == []
    assert driver.encode_signal(:unused, %{}, 1) == <<>>
    assert driver.decode_signal(:unused, %{}, <<0xAB, 0xCD>>) == <<0xAB, 0xCD>>
  end

  test "top-level API is slave-centric and EtherCAT is the only normal runtime entry point" do
    assert Code.ensure_loaded?(EtherCAT)
    assert Code.ensure_loaded?(EtherCAT.Raw)
    assert Code.ensure_loaded?(EtherCAT.Diagnostics)
    assert Code.ensure_loaded?(EtherCAT.Provisioning)
    assert Code.ensure_loaded?(EtherCAT.Endpoint)
    assert Code.ensure_loaded?(EtherCAT.Notification)
    assert Code.ensure_loaded?(EtherCAT.Sample)
    assert Code.ensure_loaded?(EtherCAT.Session)
    assert Code.ensure_loaded?(EtherCAT.Domain.Status)
    assert Code.ensure_loaded?(EtherCAT.Slave.Status)
    assert Code.ensure_loaded?(EtherCAT.SlaveDescription)
    refute Code.ensure_loaded?(Module.concat(EtherCAT, Device))

    refute function_exported?(EtherCAT, :read_input, 2)
    refute function_exported?(EtherCAT, :write_output, 3)
    refute function_exported?(EtherCAT, :configure_slave, 2)
    refute function_exported?(EtherCAT, :activate, 0)
    refute function_exported?(EtherCAT, :deactivate, 0)
    refute function_exported?(EtherCAT, :slave_info, 1)
    refute function_exported?(EtherCAT, :domain_info, 1)
    refute function_exported?(EtherCAT, :dc_status, 0)
    refute function_exported?(EtherCAT, :upload_sdo, 3)
    refute function_exported?(EtherCAT, :set_output, 3)
    refute function_exported?(EtherCAT, :set_outputs, 1)
    refute function_exported?(EtherCAT, :devices, 0)

    refute function_exported?(EtherCAT, :slaves, 0)
    assert function_exported?(EtherCAT, :slaves, 1)
    refute function_exported?(EtherCAT, :status, 1)
    assert function_exported?(EtherCAT, :status, 2)
    refute function_exported?(EtherCAT, :samples, 1)
    assert function_exported?(EtherCAT, :samples, 2)
    refute function_exported?(EtherCAT, :sample, 2)
    assert function_exported?(EtherCAT, :sample, 3)
    refute function_exported?(EtherCAT, :describe, 1)
    assert function_exported?(EtherCAT, :describe, 2)
    refute function_exported?(EtherCAT, :inventory, 0)
    assert function_exported?(EtherCAT, :inventory, 1)
    assert function_exported?(EtherCAT, :subscribe, 2)
    assert function_exported?(EtherCAT, :subscribe, 3)
    refute function_exported?(EtherCAT, :read, 2)
    assert function_exported?(EtherCAT, :read, 3)
    refute function_exported?(EtherCAT, :write, 3)
    assert function_exported?(EtherCAT, :write, 4)
    refute function_exported?(EtherCAT, :snapshot, 0)
    refute function_exported?(EtherCAT, :snapshot, 1)
    refute function_exported?(EtherCAT, :command, 3)
    refute function_exported?(EtherCAT.Raw, :read_input, 2)
    assert function_exported?(EtherCAT.Raw, :read_input, 3)
    refute function_exported?(EtherCAT.Raw, :write_output, 3)
    assert function_exported?(EtherCAT.Raw, :write_output, 4)
    assert function_exported?(EtherCAT.Raw, :subscribe, 3)
    assert function_exported?(EtherCAT.Raw, :subscribe, 4)
    refute function_exported?(EtherCAT.Diagnostics, :slave_info, 1)
    assert function_exported?(EtherCAT.Diagnostics, :slave_info, 2)
    refute function_exported?(EtherCAT.Provisioning, :upload_sdo, 3)
    assert function_exported?(EtherCAT.Provisioning, :upload_sdo, 4)
  end

  test "sessions reject calls after their generation is no longer active" do
    master = ensure_master_running()
    stale = EtherCAT.Session.new(master, make_ref())

    assert {:error, :stale_session} = EtherCAT.state(stale)
    assert {:error, :stale_session} = EtherCAT.slaves(stale)
    assert {:error, :stale_session} = EtherCAT.status(stale, :sensor)
    assert {:error, :stale_session} = EtherCAT.Diagnostics.dc_status(stale)
    assert {:error, :stale_session} = EtherCAT.Provisioning.activate(stale)
    assert {:error, :stale_session} = EtherCAT.Raw.read_input(stale, :sensor, :input)
  end

  test "master status reports stopped or idle without an active session" do
    status = EtherCAT.Master.current_status()

    assert match?(%EtherCAT.Master.Status{lifecycle: :stopped}, status) or
             match?(%EtherCAT.Master.Status{lifecycle: :idle}, status)
  end

  test "the current session is unavailable without an active generation" do
    assert {:error, :not_started} = EtherCAT.Session.current()
  end

  test "await_running returns timeout instead of exiting when the master call itself times out" do
    _pid = ensure_master_running()
    :sys.suspend(EtherCAT.Master)
    on_exit(fn -> :sys.resume(EtherCAT.Master) end)

    session = EtherCAT.Session.new(Process.whereis(EtherCAT.Master), make_ref())
    assert {:error, :timeout} = EtherCAT.await_running(session, 5)
  end

  test "await_operational returns timeout instead of exiting when the master call itself times out" do
    _pid = ensure_master_running()
    :sys.suspend(EtherCAT.Master)
    on_exit(fn -> :sys.resume(EtherCAT.Master) end)

    session = EtherCAT.Session.new(Process.whereis(EtherCAT.Master), make_ref())
    assert {:error, :timeout} = EtherCAT.await_operational(session, 5)
  end

  test "deactivate returns timeout instead of exiting when the master call itself times out" do
    _pid = ensure_master_running()
    :sys.suspend(EtherCAT.Master)
    on_exit(fn -> :sys.resume(EtherCAT.Master) end)

    session = EtherCAT.Session.new(Process.whereis(EtherCAT.Master), make_ref())
    assert {:error, :timeout} = EtherCAT.Provisioning.deactivate(session)
  end

  test "state returns timeout instead of exiting when the master call itself times out" do
    _pid = ensure_master_running()
    :sys.suspend(EtherCAT.Master)
    on_exit(fn -> :sys.resume(EtherCAT.Master) end)

    session = EtherCAT.Session.new(Process.whereis(EtherCAT.Master), make_ref())
    assert {:error, :timeout} = EtherCAT.state(session)
  end

  defp stop_current_session do
    case EtherCAT.Session.current() do
      {:ok, session} -> EtherCAT.stop(session)
      {:error, :not_started} -> :ok
    end
  end

  defp raw_backend(interface), do: {:raw, %{interface: interface}}
end
