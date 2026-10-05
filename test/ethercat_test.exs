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

  test "default slave driver exposes raw codecs and rejects nonbinary outputs" do
    driver = EtherCAT.Driver.Default

    assert driver.signal_model(%{}, []) == []
    assert driver.encode_signal(:unused, %{}, 1) == {:error, :invalid_value}
    assert driver.decode_signal(:unused, %{}, <<0xAB, 0xCD>>) == {:ok, <<0xAB, 0xCD>>}
  end

  test "top-level API is slave-centric and EtherCAT is the only normal runtime entry point" do
    assert Code.ensure_loaded?(EtherCAT)
    assert Code.ensure_loaded?(EtherCAT.Signals)
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
    refute function_exported?(EtherCAT.Signals, :read_input, 2)
    refute function_exported?(EtherCAT.Signals, :read_input, 3)
    refute function_exported?(EtherCAT.Signals, :write_output, 3)
    refute function_exported?(EtherCAT.Signals, :write_output, 4)
    assert function_exported?(EtherCAT.Signals, :subscribe, 3)
    assert function_exported?(EtherCAT.Signals, :subscribe, 4)
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
    assert {:error, :stale_session} = EtherCAT.read(stale, :sensor, :input)
  end

  test "session lookups and descriptions do not call diagnostic processes" do
    master = ensure_master_running()
    original = :sys.get_state(master)
    generation = make_ref()
    session = EtherCAT.Session.new(master, generation)
    stale = EtherCAT.Session.new(master, make_ref())

    slave = start_supervised!({Agent, fn -> nil end}, id: :lookup_slave)
    domain = start_supervised!({Agent, fn -> nil end}, id: :lookup_domain)
    bus = start_supervised!({Agent, fn -> nil end}, id: :lookup_bus)
    dc = start_supervised!({Agent, fn -> nil end}, id: :lookup_dc)

    Agent.get(slave, fn _ ->
      Registry.register(EtherCAT.Registry, {:slave, :lookup_sensor}, nil)
    end)

    Agent.get(domain, fn _ ->
      Registry.register(EtherCAT.Registry, {:domain, :lookup_main}, nil)
    end)

    Registry.register(EtherCAT.Registry, {:slave, :outside_session}, nil)
    Registry.register(EtherCAT.Registry, {:domain, :outside_session}, nil)
    Process.register(bus, EtherCAT.Bus)
    Process.register(dc, EtherCAT.DC)

    data = %EtherCAT.Master{
      generation: generation,
      desired_runtime_target: :preop,
      slaves: [lookup_sensor: 0x1001],
      slave_configs: [
        %EtherCAT.Slave.Config{name: :lookup_sensor},
        %EtherCAT.Slave.Config{name: :missing_sensor}
      ],
      domain_configs: [
        %EtherCAT.Domain.Config{id: :lookup_main, cycle_time_us: 1_000},
        %EtherCAT.Domain.Config{id: :missing_domain, cycle_time_us: 1_000}
      ],
      dc_config: %EtherCAT.DC.Config{cycle_ns: 1_000_000}
    }

    :sys.replace_state(master, fn _ -> {:preop_ready, data} end)
    Enum.each([slave, domain, bus, dc], &:sys.suspend/1)

    try do
      task =
        Task.async(fn ->
          assert {:ok, ^slave} = EtherCAT.Session.slave(session, :lookup_sensor)
          assert {:ok, ^domain} = EtherCAT.Session.domain(session, :lookup_main)

          for name <- [:missing_sensor, :outside_session] do
            assert {:error, :not_found} = EtherCAT.Session.slave(session, name)
          end

          for id <- [:missing_domain, :outside_session] do
            assert {:error, :not_found} = EtherCAT.Session.domain(session, id)
          end

          assert {:ok, description} = EtherCAT.describe(session, :lookup_sensor)
          assert description.name == :lookup_sensor
          assert {:ok, %{name: :missing_sensor}} = EtherCAT.describe(session, :missing_sensor)
          assert {:error, :not_found} = EtherCAT.describe(session, :outside_session)
          assert {:ok, inventory} = EtherCAT.inventory(session)
          assert inventory.lookup_sensor == description
          assert Map.has_key?(inventory, :missing_sensor)

          assert {:error, :stale_session} = EtherCAT.Session.slave(stale, :lookup_sensor)
          assert {:error, :stale_session} = EtherCAT.Session.domain(stale, :lookup_main)
          assert {:error, :stale_session} = EtherCAT.describe(stale, :lookup_sensor)
          assert {:error, :stale_session} = EtherCAT.inventory(stale)
        end)

      Task.await(task, 1_000)
    after
      Enum.each([slave, domain, bus, dc], &:sys.resume/1)
      :sys.replace_state(master, fn _ -> original end)
    end
  end

  test "master status reports stopped or idle without an active session" do
    status = EtherCAT.Master.current_status()

    assert status.desired_target == nil

    assert match?(%EtherCAT.Master.Status{lifecycle: :stopped}, status) or
             match?(%EtherCAT.Master.Status{lifecycle: :idle}, status)
  end

  test "the current session is unavailable without an active generation" do
    assert {:error, :not_started} = EtherCAT.Session.current()
  end

  test "await_ready returns timeout instead of exiting when the master call itself times out" do
    _pid = ensure_master_running()
    :sys.suspend(EtherCAT.Master)
    on_exit(fn -> :sys.resume(EtherCAT.Master) end)

    session = EtherCAT.Session.new(Process.whereis(EtherCAT.Master), make_ref())
    assert {:error, :timeout} = EtherCAT.await_ready(session, 5)
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
