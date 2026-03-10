defmodule EtherCAT.DeepIntegrationTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.Slave.Config, as: SlaveConfig
  alias EtherCAT.Support.Simulator
  alias EtherCAT.Support.Simulator.Udp
  alias EtherCAT.Support.Slave
  alias EtherCAT.Support.Slave.Driver

  @master_ip {127, 0, 0, 1}
  @simulator_ip {127, 0, 0, 2}

  setup tags do
    _ = EtherCAT.stop()

    fixtures = Map.get(tags, :fixtures, [Slave.digital_io(name: :sim)])

    {:ok, simulator} = Simulator.start_link(slaves: fixtures)
    {:ok, endpoint} = Udp.start_link(simulator: simulator, ip: @simulator_ip, port: 0)
    {:ok, %{port: port}} = Udp.info(endpoint)

    on_exit(fn ->
      :ok = EtherCAT.stop()

      if Process.alive?(endpoint) do
        GenServer.stop(endpoint)
      end

      if Process.alive?(simulator) do
        GenServer.stop(simulator)
      end
    end)

    {:ok, endpoint: endpoint, simulator: simulator, port: port, fixtures: fixtures}
  end

  test "boots the real master against a loopback UDP simulated slave and exchanges cyclic I/O",
       %{simulator: simulator, port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{
                   name: :sim,
                   driver: Driver,
                   process_data: [out: :main, in: :main],
                   target_state: :op
                 }
               ]
             )

    assert :ok = EtherCAT.await_operational(2_000)
    assert :operational = EtherCAT.state()

    assert :ok = EtherCAT.write_output(:sim, :out, 1)

    assert_eventually(fn ->
      assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:sim, :in)
      assert is_integer(updated_at_us)
    end)

    assert {:ok, 1} = Simulator.output_value(simulator, :sim)
  end

  @tag fixtures: [Slave.digital_io(name: :sim_a), Slave.digital_io(name: :sim_b)]
  test "boots a multi-slave simulated ring and exchanges cyclic I/O with both slaves",
       %{simulator: simulator, port: port, fixtures: fixtures} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: slave_configs(fixtures)
             )

    assert :ok = EtherCAT.await_operational(2_000)
    assert :operational = EtherCAT.state()

    assert :ok = EtherCAT.write_output(:sim_a, :out, 1)
    assert :ok = EtherCAT.write_output(:sim_b, :out, 2)

    assert_eventually(fn ->
      assert {:ok, {1, updated_a}} = EtherCAT.read_input(:sim_a, :in)
      assert {:ok, {2, updated_b}} = EtherCAT.read_input(:sim_b, :in)
      assert is_integer(updated_a)
      assert is_integer(updated_b)
    end)

    assert {:ok, 1} = Simulator.output_value(simulator, :sim_a)
    assert {:ok, 2} = Simulator.output_value(simulator, :sim_b)
  end

  @tag fixtures: [Slave.coupler(name: :coupler), Slave.lan9252_demo(name: :io)]
  test "boots a heterogeneous ring with a coupler fixture and a LAN9252-style IO slave",
       %{simulator: simulator, port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{name: :coupler, process_data: :none, target_state: :op},
                 %SlaveConfig{
                   name: :io,
                   driver: Driver,
                   config: %{profile: :lan9252_demo},
                   process_data: {:all, :main},
                   target_state: :op
                 }
               ]
             )

    assert :ok = EtherCAT.await_operational(2_000)
    assert :operational = EtherCAT.state()

    assert {:ok, %{station: 0x1000}} = EtherCAT.slave_info(:coupler)
    assert {:ok, %{station: 0x1001}} = EtherCAT.slave_info(:io)

    assert :ok = EtherCAT.write_output(:io, :led0, 1)
    assert :ok = EtherCAT.write_output(:io, :led1, 2)

    assert_eventually(fn ->
      assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:io, :button1)
      assert is_integer(updated_at_us)
    end)

    assert {:ok, <<1, 2>>} = Simulator.output_image(simulator, :io)
  end

  @tag fixtures: [Slave.lan9252_demo(name: :mailbox)]
  test "supports expedited CoE uploads and downloads in PREOP over the real UDP transport",
       %{port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{
                   name: :mailbox,
                   driver: Driver,
                   config: %{profile: :lan9252_demo},
                   process_data: :none,
                   target_state: :preop
                 }
               ]
             )

    assert :ok = EtherCAT.await_running(2_000)
    assert :preop_ready = EtherCAT.state()

    assert {:ok, <<0x34, 0x12>>} = EtherCAT.upload_sdo(:mailbox, 0x2000, 0x01)
    assert :ok = EtherCAT.download_sdo(:mailbox, 0x2000, 0x01, <<0x78, 0x56>>)
    assert {:ok, <<0x78, 0x56>>} = EtherCAT.upload_sdo(:mailbox, 0x2000, 0x01)
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, 0) do
    fun.()
  end

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error in [ExUnit.AssertionError, MatchError] ->
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
  else
    result ->
      result
  end

  defp slave_configs(fixtures) do
    Enum.map(fixtures, fn fixture ->
      %SlaveConfig{
        name: fixture.name,
        driver: Driver,
        process_data: [out: :main, in: :main],
        target_state: :op
      }
    end)
  end
end
