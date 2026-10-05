defmodule EtherCAT.MasterBoundaryTest do
  use ExUnit.Case, async: false

  alias EtherCAT.{Diagnostics, Master, Session}
  alias EtherCAT.DC.Config, as: DCConfig
  alias EtherCAT.Slave.Config, as: SlaveConfig

  defmodule Probe do
    @behaviour :gen_statem

    def start_link({name, owner}) do
      :gen_statem.start_link(name, __MODULE__, owner, [])
    end

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(owner), do: {:ok, :ready, owner}

    @impl true
    def handle_event({:call, from}, message, _state, owner) do
      send(owner, {:probe_call, self(), message, from})
      :keep_state_and_data
    end
  end

  setup do
    master = Process.whereis(Master)
    original = :sys.get_state(master)
    on_exit(fn -> :sys.replace_state(master, fn _ -> original end) end)
    %{master: master}
  end

  test "unknown, replaced, and unwrapped slave notifications cannot change the session", %{
    master: master
  } do
    slave = probe({:slave, :boundary_slave})
    old = probe({:slave, :old_slave})

    data = %Master{
      generation: make_ref(),
      desired_runtime_target: :preop,
      slaves: [boundary_slave: 0x1001],
      slave_configs: [%SlaveConfig{name: :boundary_slave, target_state: :preop}],
      runtime_faults: %{{:slave, :boundary_slave} => {:down, :disconnected}},
      slave_faults: %{boundary_slave: {:down, :disconnected}}
    }

    session = install(master, :recovering, data)

    for message <- [
          {:worker_event, slave, {:slave_ready, :unknown_slave, :preop}},
          {:worker_event, old, {:slave_ready, :boundary_slave, :preop}},
          {:slave_ready, :boundary_slave, :preop},
          {:worker_event, old, {:slave_down, :boundary_slave, :no_response}}
        ] do
      send(master, message)
      assert Session.call(session, :state) == :recovering
      assert :sys.get_state(master) == {:recovering, data}
    end

    send(master, {:worker_event, slave, {:slave_ready, :boundary_slave, :preop}})
    assert Session.call(session, :state) == :preop_ready
    {_, healed} = :sys.get_state(master)
    assert healed.runtime_faults == %{}
    assert healed.slave_faults == %{}

    # The same logical name in a later session must not accept the old pid.
    stop_supervised!({:slave, :boundary_slave})
    replacement = probe({:slave, :boundary_slave})
    replacement_data = %{data | generation: make_ref()}
    replacement_session = install(master, :recovering, replacement_data)
    send(master, {:worker_event, slave, {:slave_ready, :boundary_slave, :preop}})
    assert Session.call(replacement_session, :state) == :recovering
    send(master, {:worker_event, replacement, {:slave_ready, :boundary_slave, :preop}})
    assert Session.call(replacement_session, :state) == :preop_ready
    assert {:error, :stale_session} = Session.call(session, :state)
  end

  test "domain and DC recovery require the current worker pid", %{master: master} do
    domain = probe({:domain, :boundary_domain})
    dc = probe(EtherCAT.DC)
    other = probe({:domain, :unconfigured_domain})

    data = %Master{
      generation: make_ref(),
      desired_runtime_target: :op,
      domain_configs: [%{id: :boundary_domain, cycle_time_us: 1_000, logical_base: 0}],
      dc_config: %DCConfig{},
      dc_ref: make_ref(),
      runtime_faults: %{
        {:domain, :boundary_domain} => {:cycle_degraded, :timeout},
        {:dc, :runtime} => {:failed, :timeout}
      }
    }

    session = install(master, :recovering, data)

    for message <- [
          {:worker_event, other, {:domain_cycle_recovered, :boundary_domain}},
          {:worker_event, other, {:domain_stopped, :unconfigured_domain, :timeout}},
          {:worker_event, other, {:dc_runtime_recovered}},
          {:dc_runtime_recovered}
        ] do
      send(master, message)
      assert Session.call(session, :state) == :recovering
      assert :sys.get_state(master) == {:recovering, data}
    end

    send(master, {:worker_event, domain, {:domain_cycle_recovered, :boundary_domain}})
    assert Session.call(session, :state) == :recovering
    {_, partial} = :sys.get_state(master)
    assert partial.runtime_faults == %{{:dc, :runtime} => {:failed, :timeout}}

    send(master, {:worker_event, dc, {:dc_runtime_recovered}})
    assert Session.call(session, :state) == :operational
    {_, healed} = :sys.get_state(master)
    assert healed.runtime_faults == %{}
  end

  for source <- [:bus, :dc, :domain] do
    @source source
    test "stalled #{@source} diagnostics leave the master responsive and report a timeout", %{
      master: master
    } do
      source = @source
      {worker, data, expected_source} = diagnostic_worker(source)
      session = install(master, :operational, data)
      query = Task.async(fn -> Diagnostics.master_status(session) end)
      assert_receive {:probe_call, ^worker, _message, _from}

      assert Session.call(session, :state, 100) == :operational

      assert {:error, {:diagnostic_unavailable, ^expected_source, :timeout}} =
               Task.await(query, 2_000)

      assert Session.call(session, :state, 100) == :operational
    end
  end

  test "a stopped generation invalidates an in-flight diagnostic reply", %{master: master} do
    {worker, data, _source} = diagnostic_worker(:bus)
    session = install(master, :operational, data)
    query = Task.async(fn -> Diagnostics.master_status(session) end)
    assert_receive {:probe_call, ^worker, :info, from}

    assert :ok = EtherCAT.stop(session)
    assert {:idle, %Master{generation: nil}} = :sys.get_state(master)
    :gen_statem.reply(from, {:ok, %{state: :idle}})
    assert {:error, :stale_session} = Task.await(query)
  end

  test "captured diagnostic pids cannot resolve to replacement workers", %{master: master} do
    {worker, data, _source} = diagnostic_worker(:bus)
    session = install(master, :operational, data)
    assert {:ok, snapshot} = Session.call(session, :diagnostic_snapshot)
    stop_supervised!(EtherCAT.Bus)
    replacement = probe(EtherCAT.Bus)
    refute replacement == worker

    assert {:error, {:diagnostic_unavailable, :bus, :not_running}} =
             Master.Diagnostics.collect(snapshot, :status)

    refute_receive {:probe_call, ^replacement, _, _}
  end

  test "a domain-list query reports an unavailable domain instead of omitting it", %{
    master: master
  } do
    {worker, data, _source} = diagnostic_worker(:domain)
    session = install(master, :operational, data)
    query = Task.async(fn -> Diagnostics.domains(session) end)
    assert_receive {:probe_call, ^worker, :info, from}
    :gen_statem.reply(from, {:error, :unavailable})

    assert {:error, {:diagnostic_unavailable, {:domain, :boundary_domain}, :unavailable}} =
             Task.await(query)
  end

  test "all domain observations share one timeout budget", %{master: master} do
    first = probe({:domain, :first_domain})
    second = probe({:domain, :second_domain})

    data = %Master{
      generation: make_ref(),
      desired_runtime_target: :op,
      domain_configs: [
        %{id: :first_domain, cycle_time_us: 1_000, logical_base: 0},
        %{id: :second_domain, cycle_time_us: 1_000, logical_base: 2048}
      ]
    }

    session = install(master, :operational, data)
    query = Task.async(fn -> Diagnostics.domains(session) end)
    assert_receive {:probe_call, ^first, :info, from}
    Process.sleep(500)
    :gen_statem.reply(from, {:ok, %{cycle_time_us: 1_000}})
    assert_receive {:probe_call, ^second, :info, _from}

    # A fresh one-second budget per worker would exceed this remaining wait.
    assert {:error, {:diagnostic_unavailable, {:domain, :second_domain}, :timeout}} =
             Task.await(query, 750)
  end

  defp diagnostic_worker(source) do
    data = %Master{generation: make_ref(), desired_runtime_target: :op}

    case source do
      :bus ->
        {probe(EtherCAT.Bus), data, :bus}

      :dc ->
        {probe(EtherCAT.DC), %{data | dc_config: %DCConfig{}}, :dc}

      :domain ->
        {probe({:domain, :boundary_domain}),
         %{
           data
           | domain_configs: [%{id: :boundary_domain, cycle_time_us: 1_000, logical_base: 0}]
         }, {:domain, :boundary_domain}}
    end
  end

  defp probe(key) do
    name =
      case key do
        {kind, name} -> {:via, Registry, {EtherCAT.Registry, {kind, name}}}
        name -> {:local, name}
      end

    start_supervised!(%{id: key, start: {Probe, :start_link, [{name, self()}]}})
  end

  defp install(master, state, data) do
    :sys.replace_state(master, fn _ -> {state, data} end)
    Session.new(master, data.generation)
  end
end
